#!/usr/bin/env bash
# Phase 4 secrets - create the SOPS-encrypted Gluetun/Mullvad Secret manifest.
#
# Inputs:
#   MULLVAD_WIREGUARD_PRIVATE_KEY=...
#   MULLVAD_WIREGUARD_ADDRESSES=...
#
# Plaintext is written only under a temporary directory, then SOPS-encrypted into
# the Flux target.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl kustomize sops

[ -n "${MULLVAD_WIREGUARD_PRIVATE_KEY:-}" ] \
  || die "set MULLVAD_WIREGUARD_PRIVATE_KEY"
[ -n "${MULLVAD_WIREGUARD_ADDRESSES:-}" ] \
  || die "set MULLVAD_WIREGUARD_ADDRESSES"
[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

step "Render plaintext Gluetun Secret manifest in a temp dir"
kubectl create secret generic gluetun-mullvad \
  --namespace media \
  --from-literal=WIREGUARD_PRIVATE_KEY="$MULLVAD_WIREGUARD_PRIVATE_KEY" \
  --from-literal=WIREGUARD_ADDRESSES="$MULLVAD_WIREGUARD_ADDRESSES" \
  --dry-run=client -o yaml >"$tmpdir/gluetun-mullvad.yaml"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/gluetun-mullvad.yaml" >"$PHASE4_GLUETUN_SECRET"
ok "encrypted Secret manifest written"

step "Ensure the Secret is included by kustomize"
(
  cd "$PHASE4_DOWNLOAD_STACK_DIR"
  kustomize edit add resource gluetun-mullvad.sops.yaml >/dev/null 2>&1 || true
)
kustomize build "$REPO_ROOT/apps" >/dev/null
ok "Gluetun Secret is included in the apps Flux target"
