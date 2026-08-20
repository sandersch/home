#!/usr/bin/env bash
# Phase 4 validation - check Home Assistant after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Home Assistant rollout"
kubectl -n home-assistant rollout status deploy/home-assistant --timeout=300s
ok "Home Assistant rollout is complete"

step "Verify Home Assistant storage"
kubectl -n home-assistant get pvc home-assistant-config-pvc

step "Verify Home Assistant scheduling posture"
ha_host_network="$(kubectl -n home-assistant get deploy home-assistant -o jsonpath='{.spec.template.spec.hostNetwork}')"
ha_priority="$(kubectl -n home-assistant get deploy home-assistant -o jsonpath='{.spec.template.spec.priorityClassName}')"
[ "$ha_host_network" = "true" ] || die "expected hostNetwork=true, got '${ha_host_network:-unset}'"
[ "$ha_priority" = "homelab-critical" ] || die "expected priorityClassName=homelab-critical, got '${ha_priority:-unset}'"
ok "Home Assistant uses host networking and the critical priority class"

step "Verify Home Assistant initial config"
kubectl -n home-assistant exec deploy/home-assistant -- test -s /config/configuration.yaml
kubectl -n home-assistant exec deploy/home-assistant -- grep -q trusted_proxies /config/configuration.yaml
kubectl -n home-assistant exec deploy/home-assistant -- grep -q '^automation: !include automations.yaml$' /config/configuration.yaml
kubectl -n home-assistant exec deploy/home-assistant -- test -f /config/automations.yaml
kubectl -n home-assistant exec deploy/home-assistant -- grep -q 'alias: Person detection notification' /config/automations.yaml
kubectl -n home-assistant exec deploy/home-assistant -- grep -q 'entity_id: binary_sensor.amcrest_105_50_person_occupancy' /config/automations.yaml
ok "Home Assistant has initial reverse-proxy config and the person-detection automation"

step "Verify Home Assistant HTTP service"
# renovate: datasource=docker depName=busybox
kubectl -n home-assistant run home-assistant-http-test --restart=Never --rm -i --image=busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616 \
  -- sh -c 'for i in $(seq 1 60); do wget -qO- http://home-assistant:8123/ >/dev/null && exit 0; sleep 5; done; exit 1'
ok "Home Assistant service responded inside the home-assistant namespace"

step "Show recent Home Assistant logs"
kubectl -n home-assistant logs deploy/home-assistant --tail=100

cat <<'EOF'

Manual validation still required:
- Open https://home-assistant.worm.run.
- Complete onboarding and set the internal/external URLs if prompted.
- Add LAN integrations discovered through mDNS/Zeroconf.
- Configure Z-Wave through the dedicated Z-Wave JS UI deployment and
  runbooks/phase4/13-validate-zwave-js.sh; no USB hostPath is required.
EOF
