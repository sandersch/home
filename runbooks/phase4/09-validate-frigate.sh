#!/usr/bin/env bash
# Phase 4 validation - check Frigate after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Intel GPU plugin rollout"
kubectl -n intel-gpu-plugin rollout status ds/intel-gpu-plugin --timeout=300s
ok "Intel GPU plugin rollout is complete"

step "Verify Intel i915 shared resources are advertised"
i915_allocatable="$(kubectl get node minis -o go-template='{{ index .status.allocatable "gpu.intel.com/i915" }}')"
[ "$i915_allocatable" = "2" ] || die "expected minis to advertise gpu.intel.com/i915=2, got '${i915_allocatable:-unset}'"
ok "minis advertises gpu.intel.com/i915=2"

step "Verify Frigate rollout"
kubectl -n frigate rollout status deploy/frigate --timeout=300s
ok "Frigate rollout is complete"

step "Verify Frigate storage objects"
kubectl -n frigate get pvc \
  frigate-config-pvc \
  frigate-cache-pvc

step "Verify Frigate requests the Intel GPU resource"
frigate_i915_request="$(kubectl -n frigate get deploy frigate -o go-template='{{ range .spec.template.spec.containers }}{{ if eq .name "frigate" }}{{ index .resources.requests "gpu.intel.com/i915" }}{{ end }}{{ end }}')"
frigate_i915_limit="$(kubectl -n frigate get deploy frigate -o go-template='{{ range .spec.template.spec.containers }}{{ if eq .name "frigate" }}{{ index .resources.limits "gpu.intel.com/i915" }}{{ end }}{{ end }}')"
[ "$frigate_i915_request" = "1" ] || die "expected Frigate to request gpu.intel.com/i915=1, got '${frigate_i915_request:-unset}'"
[ "$frigate_i915_limit" = "1" ] || die "expected Frigate to limit gpu.intel.com/i915=1, got '${frigate_i915_limit:-unset}'"
ok "Frigate requests gpu.intel.com/i915=1"

step "Verify Frigate no longer uses privileged DRM hostPath access"
frigate_privileged="$(kubectl -n frigate get deploy frigate -o jsonpath='{.spec.template.spec.containers[?(@.name=="frigate")].securityContext.privileged}')"
[ -z "$frigate_privileged" ] || [ "$frigate_privileged" = "false" ] || die "Frigate container is still privileged"
if kubectl -n frigate get deploy frigate -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -qw dri; then
  die "Frigate still has a direct /dev/dri hostPath volume"
fi
ok "Frigate is not privileged and has no direct /dev/dri hostPath volume"

step "Verify Frigate config and hardware devices are visible"
kubectl -n frigate exec deploy/frigate -- test -s /config/config.yml
kubectl -n frigate exec deploy/frigate -- sh -c 'test -r /dev/dri/renderD128 && test -w /dev/dri/renderD128'
kubectl -n frigate exec deploy/frigate -- sh -c 'ls -la /dev/bus/usb >/dev/null && test -n "$(find /dev/bus/usb -type c -print -quit)"'
ok "Frigate can see config, Intel render device, and Coral USB bus"

step "Show recent Frigate logs"
kubectl -n frigate logs deploy/frigate --tail=200

cat <<'EOF'

Manual validation still required:
- Open https://frigate.worm.run.
- Confirm the amcrest_105_50 camera is live.
- Confirm logs show no QSV/VAAPI or Coral access failures after the camera starts.
EOF
