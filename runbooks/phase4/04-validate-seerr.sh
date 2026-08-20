#!/usr/bin/env bash
# Phase 4 validation - check Seerr after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Seerr rollout"
kubectl -n media rollout status deploy/seerr --timeout=300s
ok "Seerr rollout is complete"

step "Verify Seerr storage"
kubectl -n media get pvc seerr-config-pvc

step "Verify Seerr HTTP service"
# renovate: datasource=docker depName=busybox
kubectl -n media run seerr-http-test --restart=Never --rm -i --image=busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616 \
  -- wget -qO- http://seerr:5055/ >/dev/null
ok "Seerr service responded inside the media namespace"

cat <<'EOF'

Manual validation still required:
- Open https://seerr.worm.run.
- Link Seerr to Plex.
- Add Radarr at http://gluetun.media.svc.cluster.local:7878.
- Add Sonarr at http://gluetun.media.svc.cluster.local:8989.
- Submit a test request and confirm it reaches the expected *arr app.
EOF
