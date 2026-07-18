#!/usr/bin/env bash
# Phase 5.6 - create the SOPS-encrypted Restic B2 repository Secret.
#
# Required on first run:
#   B2_BUCKET=...
#   B2_ENDPOINT=https://s3.<region>.backblazeb2.com
#   B2_KEY_ID=...
#   B2_APPLICATION_KEY=...
#
# Optional:
#   RESTIC_PASSWORD=...  generated when omitted; existing values are preserved on reruns

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kubectl kustomize openssl sops

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

existing_key() {
  local key="$1"
  [ -f "$tmpdir/restic-b2.existing.json" ] || return 0
  jq -r --arg key "$key" '
    if (.stringData[$key] // "") != "" then
      .stringData[$key]
    elif (.data[$key] // "") != "" then
      .data[$key] | @base64d
    else
      empty
    end
  ' "$tmpdir/restic-b2.existing.json"
}

if [ -f "$PHASE5_RESTIC_B2_SECRET" ]; then
  step "Decrypt existing Restic B2 Secret in a temp dir to preserve unchanged values"
  sops --decrypt --output-type json "$PHASE5_RESTIC_B2_SECRET" >"$tmpdir/restic-b2.existing.json" \
    || die "could not decrypt $PHASE5_RESTIC_B2_SECRET; set SOPS_AGE_KEY_FILE or export all values"
  ok "existing Restic B2 Secret decrypted in temp dir"
fi

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$(existing_key RESTIC_REPOSITORY)}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(existing_key RESTIC_PASSWORD)}"
B2_KEY_ID="${B2_KEY_ID:-$(existing_key AWS_ACCESS_KEY_ID)}"
B2_APPLICATION_KEY="${B2_APPLICATION_KEY:-$(existing_key AWS_SECRET_ACCESS_KEY)}"

if [ -n "${B2_BUCKET:-}" ] || [ -n "${B2_ENDPOINT:-}" ]; then
  [ -n "${B2_BUCKET:-}" ] || die "B2_BUCKET is required when changing the B2 repository"
  [ -n "${B2_ENDPOINT:-}" ] || die "B2_ENDPOINT is required when changing the B2 repository"
  endpoint="${B2_ENDPOINT%/}"
  case "$endpoint" in
    https://*) ;;
    *) die "B2_ENDPOINT must be the HTTPS S3 endpoint, for example https://s3.us-west-004.backblazeb2.com" ;;
  esac
  RESTIC_REPOSITORY="s3:${endpoint}/${B2_BUCKET}/opt"
fi

[ -n "$RESTIC_REPOSITORY" ] || die "B2_BUCKET and B2_ENDPOINT are required on the first run"
[ -n "$B2_KEY_ID" ] || die "B2_KEY_ID is required on the first run"
[ -n "$B2_APPLICATION_KEY" ] || die "B2_APPLICATION_KEY is required on the first run"
if [ -z "$RESTIC_PASSWORD" ]; then
  RESTIC_PASSWORD="$(openssl rand -base64 48)"
fi

printf '%s' "$RESTIC_REPOSITORY" >"$tmpdir/RESTIC_REPOSITORY"
printf '%s' "$RESTIC_PASSWORD" >"$tmpdir/RESTIC_PASSWORD"
printf '%s' "$B2_KEY_ID" >"$tmpdir/AWS_ACCESS_KEY_ID"
printf '%s' "$B2_APPLICATION_KEY" >"$tmpdir/AWS_SECRET_ACCESS_KEY"

step "Render plaintext Restic B2 Secret manifest in a temp dir"
kubectl create secret generic restic-b2 \
  --namespace monitoring \
  --from-file="RESTIC_REPOSITORY=$tmpdir/RESTIC_REPOSITORY" \
  --from-file="RESTIC_PASSWORD=$tmpdir/RESTIC_PASSWORD" \
  --from-file="AWS_ACCESS_KEY_ID=$tmpdir/AWS_ACCESS_KEY_ID" \
  --from-file="AWS_SECRET_ACCESS_KEY=$tmpdir/AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml >"$tmpdir/restic-b2.yaml"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/restic-b2.yaml" >"$PHASE5_RESTIC_B2_SECRET"
ok "encrypted Restic B2 Secret manifest written"

step "Ensure the Secret is included by kustomize"
(
  cd "$PHASE5_MONITORING_DIR" || exit
  kustomize edit add resource restic-b2.sops.yaml >/dev/null 2>&1 || true
)
assert_phase5_restic_b2_secret_present
assert_phase5_kustomize_builds
ok "Restic B2 Secret is included in the monitoring Flux target"
