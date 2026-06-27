#!/usr/bin/env bash
# Phase 4 validation - check the first app after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify media rollout"
kubectl -n media rollout status deploy/gluetun --timeout=300s
ok "download stack rollout is complete"

step "Verify media storage objects"
kubectl -n media get pvc \
  sabnzbd-config-pvc \
  sabnzbd-incomplete-pvc \
  prowlarr-config-pvc \
  radarr-config-pvc \
  sonarr-config-pvc

step "Verify VPN egress from inside the download pod"
kubectl exec -n media deploy/gluetun -c sabnzbd -- sh -c 'wget -qO- ifconfig.me'

cat <<'EOF'

Confirm the printed IP is a Mullvad exit IP before configuring indexers or downloads.
EOF
