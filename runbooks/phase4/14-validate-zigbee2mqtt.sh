#!/usr/bin/env bash
# Phase 4 validation - check Zigbee2MQTT, its retained network state, and MQTT path.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

controller_backup_max_age_days="${CONTROLLER_BACKUP_MAX_AGE_DAYS:-30}"
[[ "$controller_backup_max_age_days" =~ ^[1-9][0-9]*$ ]] \
  || die "CONTROLLER_BACKUP_MAX_AGE_DAYS must be a positive integer"
controller_backup_max_age_seconds="$((controller_backup_max_age_days * 86400))"

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
zigbee_backup_metadata="$({
  kubectl -n zigbee2mqtt exec deploy/zigbee2mqtt -- sh -c '
    set -eu
    backup=/app/data/coordinator_backup.json
    [ -s "$backup" ]
    modified="$(stat -c %Y "$backup")"
    now="$(date +%s)"
    age="$((now - modified))"
    [ "$age" -ge 0 ]
    printf "%s\t%s\n" "$age" "$(stat -c %s "$backup")"
  '
} 2>/dev/null)" || die "Zigbee coordinator backup is missing, empty, unreadable, or future-dated"
IFS=$'\t' read -r zigbee_backup_age zigbee_backup_size <<<"$zigbee_backup_metadata"
[ "$zigbee_backup_age" -le "$controller_backup_max_age_seconds" ] \
  || die "Zigbee coordinator backup is $((zigbee_backup_age / 86400)) days old; maximum is $controller_backup_max_age_days days"
ok "Random network settings and a recent, non-empty coordinator backup are persisted on the PVC (${zigbee_backup_size} bytes)"

step "Verify frontend service and MQTT startup"
kubectl -n home-assistant exec deploy/home-assistant -- python3 -c \
  'import urllib.request; urllib.request.urlopen("http://zigbee2mqtt.zigbee2mqtt.svc.cluster.local:8080/", timeout=5).read(1)'
z2m_logs="$(kubectl -n zigbee2mqtt logs deploy/zigbee2mqtt --since=5m)"
grep -Eq "MQTT publish: topic 'zigbee2mqtt/bridge/health'.*\"mqtt\":\{\"connected\":true" <<<"$z2m_logs" \
  || die "Zigbee2MQTT has not published current health with MQTT connected"
ok "Zigbee2MQTT frontend and current authenticated MQTT health are operational"

step "Show recent Zigbee2MQTT logs"
printf '%s\n' "$z2m_logs" \
  | sed -E "s/(MQTT publish: topic '[^']+'), payload .*/\1, payload <redacted>/" \
  | tail -n 30

cat <<'EOF'

Manual validation still required:
- Open https://zigbee2mqtt.worm.run and authenticate with the encrypted frontend token.
- Confirm permit join is disabled except during an intentional pairing window.
- Pair one device, assign a stable friendly name, and confirm its entities appear
  automatically under Home Assistant's existing MQTT integration.
- Request a fresh Zigbee2MQTT backup after pairing and before coordinator firmware
  or Zigbee network changes; the validator checks coordinator_backup.json freshness.
EOF
