#!/usr/bin/env bash
# Phase 4 validation - check Zigbee2MQTT, its retained network state, and MQTT path.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Zigbee2MQTT and Mosquitto rollouts"
kubectl -n mqtt rollout status deploy/mosquitto --timeout=300s
kubectl -n zigbee2mqtt rollout status deploy/zigbee2mqtt --timeout=300s
kubectl -n zigbee2mqtt get pvc zigbee2mqtt-data-pvc
ok "Zigbee2MQTT, Mosquitto, and retained storage are ready"

step "Verify scheduling and coordinator configuration"
z2m_priority="$(kubectl -n zigbee2mqtt get deploy zigbee2mqtt -o jsonpath='{.spec.template.spec.priorityClassName}')"
[ "$z2m_priority" = "homelab-critical" ] \
  || die "expected priorityClassName=homelab-critical, got '${z2m_priority:-unset}'"
kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- \
  grep -q 'port: tcp://slzb-mrw10u.iot.matrix:7638' /app/data/configuration.yaml
kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- \
  grep -q 'adapter: zstack' /app/data/configuration.yaml
ok "Zigbee2MQTT uses the critical priority class and TI coordinator endpoint"

step "Verify generated Zigbee network identity was persisted"
if kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- \
  grep -Eq '^(  )?(network_key|pan_id|ext_pan_id): GENERATE$' /app/data/configuration.yaml; then
  die "Zigbee2MQTT did not replace all generated network settings"
fi
kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- test -s /app/data/coordinator_backup.json
ok "Random network settings and a coordinator backup are persisted on the PVC"

step "Verify frontend service and MQTT startup"
kubectl -n home-assistant exec deploy/home-assistant -- python3 -c \
  'import urllib.request; urllib.request.urlopen("http://zigbee2mqtt.zigbee2mqtt.svc.cluster.local:8080/", timeout=5).read(1)'
z2m_logs="$(kubectl -n zigbee2mqtt logs deploy/zigbee2mqtt --tail=300)"
grep -q 'Connected to MQTT server' <<<"$z2m_logs" \
  || die "Zigbee2MQTT logs do not show a successful MQTT connection"
grep -q 'Zigbee2MQTT started' <<<"$z2m_logs" \
  || die "Zigbee2MQTT logs do not show a completed startup"
ok "Zigbee2MQTT frontend and authenticated MQTT connection are operational"

step "Show recent Zigbee2MQTT logs"
printf '%s\n' "$z2m_logs" | tail -n 100

cat <<'EOF'

Manual validation still required:
- Open https://zigbee2mqtt.worm.run and authenticate with the encrypted frontend token.
- Confirm permit join is disabled except during an intentional pairing window.
- Pair one device, assign a stable friendly name, and confirm its entities appear
  automatically under Home Assistant's existing MQTT integration.
- Save a fresh copy of coordinator_backup.json in the password manager or normal
  Home Assistant-aware backup path after pairing.
EOF
