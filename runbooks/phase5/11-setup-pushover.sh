#!/usr/bin/env bash
# Phase 5.11 - encrypt Pushover credentials and activate actionable alert routing.
#
# Optional on reruns; prompted for when omitted and not already stored:
#   PUSHOVER_USER_KEY=...
#   PUSHOVER_API_TOKEN=...

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kubectl kustomize sops yq

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"
[ -f "$PHASE5_PUSHOVER_CONFIG" ] || die "missing $PHASE5_PUSHOVER_CONFIG"

umask 077
tmpdir="$(mktemp -d /tmp/homelab-pushover.XXXXXX)"
encrypted_tmp=""
changes_complete=0
secret_existed=0

cp "$PHASE5_PUSHOVER_DIR/kustomization.yaml" "$tmpdir/pushover.kustomization.before.yaml"
cp "$PHASE5_OBSERVABILITY_CONFIG_DIR/kustomization.yaml" "$tmpdir/configs.kustomization.before.yaml"
if [ -f "$PHASE5_PUSHOVER_SECRET" ]; then
  secret_existed=1
  cp "$PHASE5_PUSHOVER_SECRET" "$tmpdir/pushover.secret.before.yaml"
fi

cleanup() {
  if [ "$changes_complete" -ne 1 ]; then
    cp "$tmpdir/pushover.kustomization.before.yaml" "$PHASE5_PUSHOVER_DIR/kustomization.yaml"
    cp "$tmpdir/configs.kustomization.before.yaml" "$PHASE5_OBSERVABILITY_CONFIG_DIR/kustomization.yaml"
    if [ "$secret_existed" -eq 1 ]; then
      cp "$tmpdir/pushover.secret.before.yaml" "$PHASE5_PUSHOVER_SECRET"
    else
      rm -f "$PHASE5_PUSHOVER_SECRET"
    fi
  fi
  [ -z "$encrypted_tmp" ] || rm -f "$encrypted_tmp"
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

existing_key() {
  local key="$1"
  [ -f "$tmpdir/pushover.existing.json" ] || return 0
  jq -r --arg key "$key" '
    if (.stringData[$key] // "") != "" then
      .stringData[$key]
    elif (.data[$key] // "") != "" then
      .data[$key] | @base64d
    else
      empty
    end
  ' "$tmpdir/pushover.existing.json"
}

prompt_secret() {
  local variable="$1" prompt="$2" value
  [ -t 0 ] || die "$variable is required when stdin is not interactive"
  read -r -s -p "$prompt: " value
  printf '\n'
  printf -v "$variable" '%s' "$value"
}

if [ -f "$PHASE5_PUSHOVER_SECRET" ]; then
  step "Decrypt existing Pushover Secret in a temp dir to preserve unchanged values"
  sops --decrypt --output-type json "$PHASE5_PUSHOVER_SECRET" >"$tmpdir/pushover.existing.json" \
    || die "could not decrypt the existing Pushover Secret; set SOPS_AGE_KEY_FILE"
  ok "existing Pushover credentials are available for safe reuse"
fi

PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY:-$(existing_key user-key)}"
PUSHOVER_API_TOKEN="${PUSHOVER_API_TOKEN:-$(existing_key api-token)}"

[ -n "$PUSHOVER_USER_KEY" ] || prompt_secret PUSHOVER_USER_KEY "Pushover user key"
[ -n "$PUSHOVER_API_TOKEN" ] || prompt_secret PUSHOVER_API_TOKEN "Pushover application API token"

[[ "$PUSHOVER_USER_KEY" =~ ^[A-Za-z0-9]{30}$ ]] \
  || die "PUSHOVER_USER_KEY must be the 30-character Pushover user key"
[[ "$PUSHOVER_API_TOKEN" =~ ^[A-Za-z0-9]{30}$ ]] \
  || die "PUSHOVER_API_TOKEN must be the 30-character Pushover application API token"

printf '%s' "$PUSHOVER_USER_KEY" >"$tmpdir/user-key"
printf '%s' "$PUSHOVER_API_TOKEN" >"$tmpdir/api-token"

step "Render the plaintext Pushover Secret in a temp dir"
kubectl create secret generic pushover \
  --namespace monitoring \
  --from-file="user-key=$tmpdir/user-key" \
  --from-file="api-token=$tmpdir/api-token" \
  --dry-run=client -o yaml >"$tmpdir/pushover.yaml"

step "Encrypt the Pushover credentials with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
encrypted_tmp="$(mktemp "$PHASE5_PUSHOVER_DIR/.pushover.sops.yaml.XXXXXX")"
sops --encrypt "$tmpdir/pushover.yaml" >"$encrypted_tmp"
yq -e '
  .data["user-key"] | startswith("ENC[AES256_GCM")
' "$encrypted_tmp" >/dev/null || die "the Pushover user key was not encrypted"
yq -e '
  .data["api-token"] | startswith("ENC[AES256_GCM")
' "$encrypted_tmp" >/dev/null || die "the Pushover API token was not encrypted"
mv "$encrypted_tmp" "$PHASE5_PUSHOVER_SECRET"
encrypted_tmp=""
ok "encrypted Pushover Secret written"

step "Activate the complete Pushover component"
(
  cd "$PHASE5_PUSHOVER_DIR" || exit
  if ! yq -e '.resources | index("pushover.sops.yaml") != null' kustomization.yaml >/dev/null; then
    kustomize edit add resource pushover.sops.yaml
  fi
)
kustomize build "$PHASE5_PUSHOVER_DIR" >/dev/null
(
  cd "$PHASE5_OBSERVABILITY_CONFIG_DIR" || exit
  if ! yq -e '.resources | index("pushover") != null' kustomization.yaml >/dev/null; then
    kustomize edit add resource pushover
  fi
)
assert_phase5_pushover_invariants "$tmpdir/pushover-rendered.yaml"
assert_phase5_observability_builds

changes_complete=1
ok "Pushover is ready to commit and reconcile through monitoring-configs"
