#!/usr/bin/env bash
# Phase 5.2 - create the SOPS-encrypted Restic backup Secret.
#
# Required:
#   HOME_ASSISTANT_TOKEN=...
#
# Optional:
#   RESTIC_PASSWORD=...   generated when omitted and no existing restic-nas Secret exists
#   ROMM_DB_PASSWORD=...  read from apps/media/romm/romm.sops.yaml MARIADB_PASSWORD when omitted

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kubectl kustomize openssl sops yq

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

existing_key() {
  local key="$1"
  [ -f "$tmpdir/restic-nas.existing.json" ] || return 0
  jq -r --arg key "$key" '
    if (.stringData[$key] // "") != "" then
      .stringData[$key]
    elif (.data[$key] // "") != "" then
      .data[$key] | @base64d
    else
      empty
    end
  ' "$tmpdir/restic-nas.existing.json"
}

romm_secret_value() {
  local key="$1"
  jq -r --arg key "$key" '
    if (.stringData[$key] // "") != "" then
      .stringData[$key]
    elif (.data[$key] // "") != "" then
      .data[$key] | @base64d
    else
      empty
    end
  ' "$tmpdir/romm.json"
}

if [ -f "$PHASE5_RESTIC_SECRET" ]; then
  step "Decrypt existing Restic Secret in a temp dir to preserve unchanged values"
  sops --decrypt --output-type json "$PHASE5_RESTIC_SECRET" >"$tmpdir/restic-nas.existing.json" \
    || die "could not decrypt $PHASE5_RESTIC_SECRET; set SOPS_AGE_KEY_FILE or export all values"
  ok "existing Restic Secret decrypted in temp dir"
fi

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  RESTIC_PASSWORD="$(existing_key RESTIC_PASSWORD)"
fi
if [ -z "${RESTIC_PASSWORD:-}" ]; then
  RESTIC_PASSWORD="$(openssl rand -base64 48)"
  export RESTIC_PASSWORD
fi

if [ -z "${HOME_ASSISTANT_TOKEN:-}" ]; then
  HOME_ASSISTANT_TOKEN="$(existing_key HOME_ASSISTANT_TOKEN)"
fi
[ -n "${HOME_ASSISTANT_TOKEN:-}" ] || die "HOME_ASSISTANT_TOKEN is required"

if [ -z "${ROMM_DB_PASSWORD:-}" ]; then
  [ -f "$PHASE5_ROMM_SECRET" ] || die "missing $PHASE5_ROMM_SECRET"
  step "Decrypt RomM Secret in a temp dir to read MARIADB_PASSWORD"
  sops --decrypt --output-type json "$PHASE5_ROMM_SECRET" >"$tmpdir/romm.json"
  romm_secret_value MARIADB_PASSWORD >"$tmpdir/ROMM_DB_PASSWORD"
  [ -s "$tmpdir/ROMM_DB_PASSWORD" ] || die "could not read MARIADB_PASSWORD from RomM Secret"

  romm_secret_value DB_PASSWD >"$tmpdir/DB_PASSWD"
  if [ -s "$tmpdir/DB_PASSWD" ] && ! cmp -s "$tmpdir/DB_PASSWD" "$tmpdir/ROMM_DB_PASSWORD"; then
    warn "RomM DB_PASSWD and MARIADB_PASSWORD differ; the backup dump uses MARIADB_PASSWORD"
  fi
else
  printf '%s' "$ROMM_DB_PASSWORD" >"$tmpdir/ROMM_DB_PASSWORD"
fi

printf '%s' "$RESTIC_PASSWORD" >"$tmpdir/RESTIC_PASSWORD"
printf '%s' "$HOME_ASSISTANT_TOKEN" >"$tmpdir/HOME_ASSISTANT_TOKEN"

step "Render plaintext Restic Secret manifest in a temp dir"
kubectl create secret generic restic-nas \
  --namespace monitoring \
  --from-file="RESTIC_PASSWORD=$tmpdir/RESTIC_PASSWORD" \
  --from-file="HOME_ASSISTANT_TOKEN=$tmpdir/HOME_ASSISTANT_TOKEN" \
  --from-file="ROMM_DB_PASSWORD=$tmpdir/ROMM_DB_PASSWORD" \
  --dry-run=client -o yaml >"$tmpdir/restic-nas.yaml"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/restic-nas.yaml" >"$PHASE5_RESTIC_SECRET"
ok "encrypted Restic Secret manifest written"

step "Ensure the Secret is included by kustomize"
(
  cd "$PHASE5_MONITORING_DIR" || exit
  kustomize edit add resource restic-nas.sops.yaml >/dev/null 2>&1 || true
)
assert_phase5_kustomize_builds
ok "Restic Secret is included in the monitoring Flux target"
