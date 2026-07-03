#!/usr/bin/env bash
# Phase 4 validation - check Mosquitto and the Frigate/Home Assistant MQTT path.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Mosquitto rollout"
kubectl -n mqtt rollout status deploy/mosquitto --timeout=300s
ok "Mosquitto rollout is complete"

step "Verify Mosquitto service and storage"
kubectl -n mqtt get svc mosquitto
kubectl -n mqtt get pvc mosquitto-data-pvc
ok "Mosquitto service and PVC exist"

step "Verify Frigate is configured for MQTT"
kubectl -n frigate exec deploy/frigate -- sh -c "grep -q 'enabled: true' /config/config.yml && grep -q 'mosquitto.mqtt.svc.cluster.local' /config/config.yml"
ok "Frigate config points at Mosquitto"

step "Show recent Mosquitto logs"
kubectl -n mqtt logs deploy/mosquitto --tail=100

cat <<'EOF'

Manual validation still required:
- In Home Assistant, add the MQTT integration with host
  mosquitto.mqtt.svc.cluster.local and port 1883.
- Install the Frigate integration from HACS if it is not present.
- Add the Frigate integration with URL http://frigate.frigate.svc.cluster.local:8971.
- Confirm Frigate devices/entities appear and Frigate availability is online.
EOF
