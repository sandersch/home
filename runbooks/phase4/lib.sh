#!/usr/bin/env bash
# Phase 4 helpers.
#
# Phase 4 starts GitOps-managed workloads.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PHASE4_DOWNLOAD_STACK_DIR="$REPO_ROOT/apps/media/download-stack"
PHASE4_GLUETUN_SECRET="$PHASE4_DOWNLOAD_STACK_DIR/gluetun-mullvad.sops.yaml"
PHASE4_ROMM_DIR="$REPO_ROOT/apps/media/romm"
PHASE4_ROMM_SECRET="$PHASE4_ROMM_DIR/romm.sops.yaml"
PHASE4_FRIGATE_DIR="$REPO_ROOT/apps/frigate"
PHASE4_FRIGATE_SECRET="$PHASE4_FRIGATE_DIR/frigate.sops.yaml"
PHASE4_HOME_ASSISTANT_DIR="$REPO_ROOT/apps/home-assistant"

assert_phase4_plex_tree() {
  local f
  for f in \
    apps/media/plex/kustomization.yaml \
    apps/media/plex/deployment.yaml \
    apps/media/plex/service.yaml \
    apps/media/plex/ingress.yaml \
    apps/media/plex/storage.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 4 Plex file: $f"
  done
  ok "Phase 4 Plex tree is present"
}

assert_phase4_download_stack_tree() {
  local f
  for f in \
    apps/kustomization.yaml \
    apps/media/kustomization.yaml \
    apps/media/namespace.yaml \
    apps/media/download-stack/kustomization.yaml \
    apps/media/download-stack/configmap.yaml \
    apps/media/download-stack/deployment.yaml \
    apps/media/download-stack/service.yaml \
    apps/media/download-stack/ingress.yaml \
    apps/media/download-stack/storage.yaml \
    apps/media/download-stack/sabnzbd-incomplete-pvc.yaml \
    apps/media/download-stack/qbittorrent-incomplete-pvc.yaml; do
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

assert_phase4_romm_tree() {
  local f
  for f in \
    apps/media/romm/kustomization.yaml \
    apps/media/romm/deployment.yaml \
    apps/media/romm/service.yaml \
    apps/media/romm/ingress.yaml \
    apps/media/romm/storage.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 4 RomM file: $f"
  done
  ok "Phase 4 RomM tree is present"
}

assert_phase4_romm_secret_present() {
  [ -f "$PHASE4_ROMM_SECRET" ] \
    || die "missing $PHASE4_ROMM_SECRET"
  grep -q '^sops:' "$PHASE4_ROMM_SECRET" \
    || die "$PHASE4_ROMM_SECRET is not SOPS-encrypted"
  ok "RomM Secret manifest is SOPS-encrypted"
}

assert_phase4_frigate_tree() {
  local f
  for f in \
    apps/frigate/kustomization.yaml \
    apps/frigate/namespace.yaml \
    apps/frigate/config.yml \
    apps/frigate/deployment.yaml \
    apps/frigate/service.yaml \
    apps/frigate/ingress.yaml \
    apps/frigate/storage.yaml \
    runbooks/phase4/08-install-frigate-config.sh \
    runbooks/phase4/09-validate-frigate.sh; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 4 Frigate file: $f"
  done
  ok "Phase 4 Frigate tree is present"
}

assert_phase4_frigate_secret_present() {
  [ -f "$PHASE4_FRIGATE_SECRET" ] \
    || die "missing $PHASE4_FRIGATE_SECRET; run runbooks/phase4/07-encrypt-frigate-secrets.sh"
  grep -q '^sops:' "$PHASE4_FRIGATE_SECRET" \
    || die "$PHASE4_FRIGATE_SECRET is not SOPS-encrypted"
  ok "Frigate Secret manifest is SOPS-encrypted"
}

assert_phase4_home_assistant_tree() {
  local f
  for f in \
    apps/home-assistant/kustomization.yaml \
    apps/home-assistant/namespace.yaml \
    apps/home-assistant/deployment.yaml \
    apps/home-assistant/service.yaml \
    apps/home-assistant/ingress.yaml \
    apps/home-assistant/storage.yaml \
    runbooks/phase4/10-validate-home-assistant.sh; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 4 Home Assistant file: $f"
  done
  ok "Phase 4 Home Assistant tree is present"
}
