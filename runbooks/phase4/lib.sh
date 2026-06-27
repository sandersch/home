#!/usr/bin/env bash
# Phase 4 helpers.
#
# Phase 4 starts GitOps-managed workloads.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PHASE4_DOWNLOAD_STACK_DIR="$REPO_ROOT/apps/media/download-stack"
PHASE4_GLUETUN_SECRET="$PHASE4_DOWNLOAD_STACK_DIR/gluetun-mullvad.sops.yaml"

assert_phase4_download_stack_tree() {
  local f
  for f in \
    apps/kustomization.yaml \
    apps/media/kustomization.yaml \
    apps/media/namespace.yaml \
    apps/media/download-stack/kustomization.yaml \
    apps/media/download-stack/deployment.yaml \
    apps/media/download-stack/service.yaml \
    apps/media/download-stack/ingress.yaml \
    apps/media/download-stack/storage.yaml \
    apps/media/download-stack/sabnzbd-incomplete-pvc.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 4 file: $f"
  done
  ok "Phase 4 download stack tree is present"
}

assert_phase4_secret_present() {
  [ -f "$PHASE4_GLUETUN_SECRET" ] \
    || die "missing $PHASE4_GLUETUN_SECRET; run runbooks/phase4/01-encrypt-download-secrets.sh"
  grep -q '^sops:' "$PHASE4_GLUETUN_SECRET" \
    || die "$PHASE4_GLUETUN_SECRET is not SOPS-encrypted"
  ok "Gluetun Mullvad Secret manifest is SOPS-encrypted"
}
