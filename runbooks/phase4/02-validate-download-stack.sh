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
  qbittorrent-config-pvc \
  qbittorrent-incomplete-pvc \
  prowlarr-config-pvc \
  radarr-config-pvc \
  sonarr-config-pvc

step "Verify Gluetun non-secret config"
kubectl -n media get configmap gluetun-config

step "Verify download stack ingress objects"
kubectl -n media get ingress \
  sabnzbd \
  qbittorrent \
  prowlarr \
  radarr \
  sonarr

step "Verify qBittorrent Web UI responds inside the VPN pod"
kubectl exec -n media deploy/gluetun -c qbittorrent -- sh -c 'wget -qO- http://127.0.0.1:8090/ >/dev/null'
ok "qBittorrent Web UI is reachable on localhost:8090"

step "Verify VPN egress from inside the download pod"
kubectl exec -n media deploy/gluetun -c sabnzbd -- sh -c \
  'wget -qO- https://am.i.mullvad.net/connected'

cat <<'EOF'

Confirm the output says the tunnel is connected to Mullvad before configuring indexers or downloads.
Then open https://qbittorrent.worm.run, complete first-login Web UI setup, and add
qBittorrent to Radarr/Sonarr as localhost:8090 while keeping SABnzbd on localhost:8080.
EOF
