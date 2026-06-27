#!/usr/bin/env bash
# Phase 4 validation - check Plex after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Plex rollout"
kubectl -n media rollout status deploy/plex --timeout=300s
ok "Plex rollout is complete"

step "Verify Plex storage objects"
kubectl -n media get pvc \
  plex-config-pvc \
  plex-transcode-pvc

step "Verify Quick Sync device is visible in the Plex pod"
kubectl -n media exec deploy/plex -- ls -l /dev/dri

step "Verify Plex HTTP endpoint through the pod loopback"
kubectl -n media exec deploy/plex -- sh -c 'wget -qO- http://127.0.0.1:32400/identity | head -c 300; echo'

cat <<'EOF'

Manual validation still required:
- Confirm the migrated server appears in Plex without setting PLEX_CLAIM.
- In Plex settings, set the custom server access URL to https://plex.worm.run.
- Keep Plex native Remote Access disabled.
- Set the Transcoder temporary directory to /transcode.
- Run a forced 1080p transcode and confirm hardware transcode in Plex or with intel_gpu_top on the host.
- Run Clean Bundles, Empty Trash, and Clean Metadata Bundles.
EOF
