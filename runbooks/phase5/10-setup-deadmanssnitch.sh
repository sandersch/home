#!/usr/bin/env bash
# Phase 5.10 - encrypt the Dead Man's Snitch URL and activate Watchdog routing.
#
# Optional:
#   DEADMANS_SNITCH_URL=https://nosnch.in/...  prompted for when omitted

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kubectl kustomize sops yq

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

existing_url() {
  [ -f "$PHASE5_DEADMANS_SNITCH_SECRET" ] || return 0
  sops --decrypt --output-type json "$PHASE5_DEADMANS_SNITCH_SECRET" \
    >"$tmpdir/deadmanssnitch.existing.json" \
    || die "could not decrypt the existing Dead Man's Snitch Secret"
  jq -r '
    if (.stringData.url // "") != "" then
      .stringData.url
    elif (.data.url // "") != "" then
      .data.url | @base64d
    else
      empty
    end
  ' "$tmpdir/deadmanssnitch.existing.json"
}

snitch_url="${DEADMANS_SNITCH_URL:-$(existing_url)}"
if [ -z "$snitch_url" ]; then
  [ -t 0 ] || die "DEADMANS_SNITCH_URL is required when stdin is not interactive"
  read -r -s -p "Dead Man's Snitch check-in URL: " snitch_url
  printf '\n'
fi

case "$snitch_url" in
  https://nosnch.in/*) ;;
  *) die "the check-in URL must start with https://nosnch.in/" ;;
esac
case "$snitch_url" in
  *[[:space:]]*) die "the check-in URL must not contain whitespace" ;;
esac
[ "$snitch_url" != "https://nosnch.in/" ] || die "the check-in URL is missing its Snitch token"

printf '%s' "$snitch_url" >"$tmpdir/url"

step "Render the plaintext check-in Secret in a temp dir"
kubectl create secret generic deadmanssnitch \
  --namespace monitoring \
  --from-file="url=$tmpdir/url" \
  --dry-run=client -o yaml >"$tmpdir/deadmanssnitch.yaml"

step "Encrypt the check-in URL with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/deadmanssnitch.yaml" >"$PHASE5_DEADMANS_SNITCH_SECRET"
ok "encrypted Dead Man's Snitch Secret written"

step "Activate the Secret and Alertmanager Watchdog route"
(
  cd "$PHASE5_DEADMANS_SNITCH_DIR" || exit
  if ! yq -e '.resources | index("deadmanssnitch.sops.yaml") != null' kustomization.yaml >/dev/null; then
    kustomize edit add resource deadmanssnitch.sops.yaml
  fi
)
(
  cd "$PHASE5_OBSERVABILITY_CONFIG_DIR" || exit
  if ! yq -e '.resources | index("deadmanssnitch") != null' kustomization.yaml >/dev/null; then
    kustomize edit add resource deadmanssnitch
  fi
)
assert_phase5_observability_builds

ok "Dead Man's Snitch is ready to reconcile"
printf '%s\n' "Configure this Snitch for a 10-minute Basic interval; Alertmanager checks in every 5 minutes."
