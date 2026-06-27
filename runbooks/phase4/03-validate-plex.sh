#!/usr/bin/env bash
# Phase 4 validation - check Plex after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Intel GPU plugin rollout"
kubectl -n intel-gpu-plugin rollout status ds/intel-gpu-plugin --timeout=300s
ok "Intel GPU plugin rollout is complete"

step "Verify Intel i915 resource is advertised"
i915_allocatable="$(kubectl get node minis -o go-template='{{ index .status.allocatable "gpu.intel.com/i915" }}')"
[ "$i915_allocatable" = "1" ] || die "expected minis to advertise gpu.intel.com/i915=1, got '${i915_allocatable:-unset}'"
ok "minis advertises gpu.intel.com/i915=1"

step "Verify Plex rollout"
kubectl -n media rollout status deploy/plex --timeout=300s
ok "Plex rollout is complete"

step "Verify Plex storage objects"
kubectl -n media get pvc \
  plex-config-pvc \
  plex-transcode-pvc

step "Verify Plex requests the Intel GPU resource"
plex_i915_limit="$(kubectl -n media get deploy plex -o go-template='{{ range .spec.template.spec.containers }}{{ if eq .name "plex" }}{{ index .resources.limits "gpu.intel.com/i915" }}{{ end }}{{ end }}')"
[ "$plex_i915_limit" = "1" ] || die "expected Plex to limit gpu.intel.com/i915=1, got '${plex_i915_limit:-unset}'"
ok "Plex requests gpu.intel.com/i915=1"

step "Verify Quick Sync device is visible and openable in the Plex pod"
kubectl -n media exec deploy/plex -- sh -c 'ls -l /dev/dri && su -s /bin/sh abc -c "test -r /dev/dri/renderD128 && test -w /dev/dri/renderD128"'

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
