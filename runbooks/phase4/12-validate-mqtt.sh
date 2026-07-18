#!/usr/bin/env bash
# Phase 4 validation - check Mosquitto and the complete Frigate/Home Assistant
# MQTT path. Run this after configuring MQTT, HACS, and Frigate in Home Assistant.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

validation_pod="mqtt-validation-$$"

cleanup() {
  kubectl -n mqtt delete pod "$validation_pod" --ignore-not-found --wait=false \
    >/dev/null 2>&1 || true
}

trap cleanup EXIT

step "Verify Mosquitto rollout"
kubectl -n mqtt rollout status deploy/mosquitto --timeout=300s
ok "Mosquitto rollout is complete"

step "Verify Mosquitto service and storage"
kubectl -n mqtt get svc mosquitto
kubectl -n mqtt get pvc mosquitto-data-pvc
ok "Mosquitto service and PVC exist"

step "Verify the broker and Frigate Secrets use the same Frigate account"
broker_frigate_user="$(kubectl -n mqtt get secret mosquitto-auth \
  -o jsonpath='{.data.MOSQUITTO_FRIGATE_USER}')"
broker_frigate_password="$(kubectl -n mqtt get secret mosquitto-auth \
  -o jsonpath='{.data.MOSQUITTO_FRIGATE_PASSWORD}')"
client_frigate_user="$(kubectl -n frigate get secret frigate-mqtt \
  -o jsonpath='{.data.FRIGATE_MQTT_USER}')"
client_frigate_password="$(kubectl -n frigate get secret frigate-mqtt \
  -o jsonpath='{.data.FRIGATE_MQTT_PASSWORD}')"

[ -n "$broker_frigate_user" ] || die "Mosquitto Frigate username is empty"
[ -n "$broker_frigate_password" ] || die "Mosquitto Frigate password is empty"
[ "$broker_frigate_user" = "$client_frigate_user" ] \
  || die "Mosquitto and Frigate MQTT usernames do not match"
[ "$broker_frigate_password" = "$client_frigate_password" ] \
  || die "Mosquitto and Frigate MQTT passwords do not match"
unset broker_frigate_user broker_frigate_password client_frigate_user client_frigate_password
ok "Mosquitto and Frigate MQTT credentials match"

step "Verify Frigate is configured for MQTT"
kubectl -n frigate exec deploy/frigate -- sh -c "grep -q 'enabled: true' /config/config.yml && grep -q 'mosquitto.mqtt.svc.cluster.local' /config/config.yml"
ok "Frigate config points at Mosquitto"

step "Verify authenticated MQTT traffic and Frigate availability"
cleanup
kubectl create -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $validation_pod
  namespace: mqtt
  labels:
    app.kubernetes.io/name: mqtt-validation
spec:
  restartPolicy: Never
  containers:
    - name: mqtt-validation
      image: eclipse-mosquitto:2
      envFrom:
        - secretRef:
            name: mosquitto-auth
      command:
        - sh
        - -c
      args:
        - |
          set -eu
          topic="homelab/validation/\${HOSTNAME}"
          payload="mqtt-validation-ok"

          mosquitto_sub \
            -h mosquitto.mqtt.svc.cluster.local \
            -p 1883 \
            -u "\$MOSQUITTO_HOME_ASSISTANT_USER" \
            -P "\$MOSQUITTO_HOME_ASSISTANT_PASSWORD" \
            -t "\$topic" \
            -C 1 \
            -W 15 \
            > /tmp/message &
          subscriber_pid=\$!
          sleep 1
          mosquitto_pub \
            -h mosquitto.mqtt.svc.cluster.local \
            -p 1883 \
            -u "\$MOSQUITTO_HOME_ASSISTANT_USER" \
            -P "\$MOSQUITTO_HOME_ASSISTANT_PASSWORD" \
            -t "\$topic" \
            -m "\$payload"
          wait "\$subscriber_pid"
          [ "\$(cat /tmp/message)" = "\$payload" ]

          availability="\$(mosquitto_sub \
            -h mosquitto.mqtt.svc.cluster.local \
            -p 1883 \
            -u "\$MOSQUITTO_HOME_ASSISTANT_USER" \
            -P "\$MOSQUITTO_HOME_ASSISTANT_PASSWORD" \
            -t frigate/available \
            -C 1 \
            -W 15)"
          [ "\$availability" = "online" ]

          if mosquitto_pub \
            -h mosquitto.mqtt.svc.cluster.local \
            -p 1883 \
            -t "\$topic/anonymous-denied" \
            -m denied \
            >/dev/null 2>&1; then
            echo "anonymous MQTT publish unexpectedly succeeded" >&2
            exit 1
          fi

          if mosquitto_pub \
            -h mosquitto.mqtt.svc.cluster.local \
            -p 1883 \
            -u "\$MOSQUITTO_HOME_ASSISTANT_USER" \
            -P deliberately-wrong-password \
            -t "\$topic/bad-password-denied" \
            -m denied \
            >/dev/null 2>&1; then
            echo "MQTT publish with a bad password unexpectedly succeeded" >&2
            exit 1
          fi

          echo "authenticated round trip, Frigate availability, and access rejection passed"
EOF

if ! kubectl -n mqtt wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  "pod/$validation_pod" \
  --timeout=60s; then
  kubectl -n mqtt logs "$validation_pod" || true
  die "authenticated MQTT validation failed"
fi
kubectl -n mqtt logs "$validation_pod"
ok "MQTT authentication and Frigate availability are operational"

step "Verify Home Assistant has MQTT, HACS, and Frigate configured"
for integration in mqtt hacs frigate; do
  kubectl -n home-assistant exec deploy/home-assistant -c home-assistant -- sh -c \
    "grep -Eq '\"domain\"[[:space:]]*:[[:space:]]*\"$integration\"' /config/.storage/core.config_entries" \
    || die "Home Assistant does not have a $integration config entry"
done
kubectl -n home-assistant exec deploy/home-assistant -c home-assistant -- \
  test -d /config/custom_components/hacs
kubectl -n home-assistant exec deploy/home-assistant -c home-assistant -- \
  test -d /config/custom_components/frigate
ok "Home Assistant has MQTT, HACS, and Frigate integrations"

step "Verify Home Assistant can reach Frigate through valid HTTPS"
frigate_status="$(kubectl -n home-assistant exec deploy/home-assistant -c home-assistant -- sh -c \
  'curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 https://frigate.worm.run/api/version')"
case "$frigate_status" in
  200|401) ;;
  *) die "Frigate HTTPS endpoint returned HTTP $frigate_status from Home Assistant" ;;
esac
ok "Home Assistant reaches the authenticated Frigate HTTPS endpoint"

step "Check recent Frigate and Home Assistant MQTT logs"
recent_errors="$(
  {
    kubectl -n frigate logs deploy/frigate --since=10m
    kubectl -n home-assistant logs deploy/home-assistant -c home-assistant --since=10m
  } 2>&1 | grep -Ei 'mqtt.*(error|failed|refused|not authorised|bad username)|(error|failed|refused|not authorised|bad username).*mqtt' || true
)"
if [ -n "$recent_errors" ]; then
  printf '%s\n' "$recent_errors"
  die "recent logs contain MQTT connection or authentication errors"
fi
ok "Recent Frigate and Home Assistant logs contain no MQTT errors"

cat <<'EOF'

Final manual event validation:
- In Home Assistant's MQTT integration, listen to frigate/#.
- Trigger a person event in the amcrest_105_50 camera view.
- Confirm a current frigate/events message arrives and the matching Frigate entities
  update in Home Assistant.
EOF
