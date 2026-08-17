#!/usr/bin/env bash
# Phase 5.15 - validate the live Zigbee2MQTT ingress and MQTT-native bridge
# monitoring path without interrupting the service or publishing synthetic MQTT state.
#
# Optional:
#   ZIGBEE2MQTT_EXPORTER_LOCAL_PORT=19100
#   ZIGBEE2MQTT_PROMETHEUS_LOCAL_PORT=19101

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools awk curl jq kubectl kustomize seq yq

exporter_port="${ZIGBEE2MQTT_EXPORTER_LOCAL_PORT:-19100}"
prometheus_port="${ZIGBEE2MQTT_PROMETHEUS_LOCAL_PORT:-19101}"

for port_spec in \
  "ZIGBEE2MQTT_EXPORTER_LOCAL_PORT:$exporter_port" \
  "ZIGBEE2MQTT_PROMETHEUS_LOCAL_PORT:$prometheus_port"; do
  port_name="${port_spec%%:*}"
  port_value="${port_spec##*:}"
  [[ "$port_value" =~ ^[0-9]+$ ]] \
    && [ "$port_value" -ge 1024 ] \
    && [ "$port_value" -le 65535 ] \
    || die "$port_name must be an unprivileged TCP port"
done
[ "$exporter_port" != "$prometheus_port" ] \
  || die "exporter and Prometheus local ports must differ"

tmpdir="$(mktemp -d /tmp/homelab-zigbee2mqtt-monitoring-validate.XXXXXX)"
exporter_forward_pid=""
prometheus_forward_pid=""
cleanup() {
  for pid in "$exporter_forward_pid" "$prometheus_forward_pid"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_for_http() {
  local url="$1" log_file="$2" pid="$3" ready=0
  for _ in $(seq 1 30); do
    if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    sed -n '1,120p' "$log_file" >&2
    die "port-forward endpoint did not become ready: $url"
  fi
}

prom_query() {
  local query="$1"
  curl --fail --silent --show-error --get \
    --data-urlencode "query=$query" \
    "http://127.0.0.1:$prometheus_port/api/v1/query"
}

raw_metric_value() {
  local metric="$1" value
  value="$({
    awk -v metric="$metric" '
      $1 == metric { count += 1; value = $2 }
      END {
        if (count == 1) print value
        else exit 1
      }
    ' "$tmpdir/exporter-metrics.txt"
  })" || die "exporter does not expose exactly one $metric sample"
  printf '%s\n' "$value"
}

step "Verify rendered Zigbee2MQTT monitoring invariants"
assert_phase5_observability_builds
assert_phase5_observability_invariants

step "Verify the kubeconfig can open read-only validation port-forwards"
[ "$(kubectl auth can-i create pods/portforward -n zigbee2mqtt)" = "yes" ] \
  || die "current kubeconfig cannot port-forward in zigbee2mqtt; switch explicitly to homelab-admin"
[ "$(kubectl auth can-i create pods/portforward -n monitoring)" = "yes" ] \
  || die "current kubeconfig cannot port-forward in monitoring; switch explicitly to homelab-admin"
ok "current kubeconfig can open both required port-forwards"

step "Verify deployed Zigbee2MQTT monitoring resources"
kubectl -n zigbee2mqtt rollout status deploy/zigbee2mqtt --timeout=300s
kubectl -n zigbee2mqtt rollout status deploy/zigbee2mqtt-mqtt-exporter --timeout=300s
[ "$(kubectl -n zigbee2mqtt get deploy zigbee2mqtt -o jsonpath='{.spec.template.spec.priorityClassName}')" = "homelab-critical" ] \
  || die "Zigbee2MQTT is not using priorityClassName=homelab-critical"
[ "$(kubectl -n zigbee2mqtt get deploy zigbee2mqtt-mqtt-exporter -o jsonpath='{.spec.template.spec.priorityClassName}')" = "homelab-critical" ] \
  || die "Zigbee2MQTT MQTT exporter is not using priorityClassName=homelab-critical"
kubectl -n zigbee2mqtt get service zigbee2mqtt-mqtt-exporter >/dev/null
kubectl -n monitoring get servicemonitor zigbee2mqtt-mqtt-health >/dev/null
kubectl -n monitoring get probe critical-ingress >/dev/null
kubectl -n monitoring get probe zigbee-coordinator >/dev/null
kubectl -n monitoring get prometheusrule homelab-alerts >/dev/null
exporter_pod="$({
  kubectl -n zigbee2mqtt get pods \
    -l app.kubernetes.io/name=zigbee2mqtt-mqtt-exporter \
    --field-selector=status.phase=Running -o json \
    | jq -r '
        [.items[] |
          select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] |
        if length == 1 then .[0].metadata.name else empty end
      '
})"
[ -n "$exporter_pod" ] \
  || die "expected exactly one Ready Zigbee2MQTT MQTT exporter pod"
ok "Zigbee2MQTT and its MQTT exporter are Ready at critical priority"

step "Verify the exporter exposes current retained bridge health"
kubectl -n zigbee2mqtt port-forward service/zigbee2mqtt-mqtt-exporter \
  "$exporter_port:9000" >"$tmpdir/exporter-port-forward.log" 2>&1 &
exporter_forward_pid=$!
wait_for_http "http://127.0.0.1:$exporter_port/metrics" \
  "$tmpdir/exporter-port-forward.log" "$exporter_forward_pid"
curl --fail --silent --show-error \
  "http://127.0.0.1:$exporter_port/metrics" >"$tmpdir/exporter-metrics.txt"

bridge_state="$(raw_metric_value 'mqtt_state{topic="zigbee2mqtt_bridge_state"}')"
mqtt_connected="$(raw_metric_value 'mqtt_mqtt_connected{topic="zigbee2mqtt_bridge_health"}')"
health_timestamp_ms="$(raw_metric_value 'mqtt_response_time{topic="zigbee2mqtt_bridge_health"}')"
jq -en --arg value "$bridge_state" '($value | tonumber) == 1' >/dev/null \
  || die "Zigbee2MQTT retained bridge state is not online"
jq -en --arg value "$mqtt_connected" '($value | tonumber) == 1' >/dev/null \
  || die "Zigbee2MQTT health reports its MQTT client disconnected"
jq -en --arg value "$health_timestamp_ms" \
  '($value | tonumber) > 0' >/dev/null \
  || die "Zigbee2MQTT health timestamp is not numeric and positive"
ok "exporter reports bridge online, MQTT connected, and a health timestamp"

step "Verify Prometheus target, ingress probe, metrics, and alert rule"
kubectl -n monitoring port-forward service/kube-prometheus-stack-prometheus \
  "$prometheus_port:9090" >"$tmpdir/prometheus-port-forward.log" 2>&1 &
prometheus_forward_pid=$!
wait_for_http "http://127.0.0.1:$prometheus_port/-/ready" \
  "$tmpdir/prometheus-port-forward.log" "$prometheus_forward_pid"

curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/targets?state=active" \
  | jq -e '
      [.data.activeTargets[] |
        select(
          .scrapePool == "serviceMonitor/monitoring/zigbee2mqtt-mqtt-health/0" and
          .labels.namespace == "zigbee2mqtt" and
          .labels.service == "zigbee2mqtt-mqtt-exporter"
        )] as $targets |
      ($targets | length) == 1 and
      $targets[0].health == "up" and
      $targets[0].lastError == ""
    ' >/dev/null \
  || die "Prometheus does not have exactly one healthy Zigbee2MQTT MQTT exporter target"

prom_query \
  "mqtt_state{namespace=\"zigbee2mqtt\",pod=\"$exporter_pod\",topic=\"zigbee2mqtt_bridge_state\"}" \
  | jq -e '
      .status == "success" and
      (.data.result | length) == 1 and
      (.data.result[0].value[1] | tonumber) == 1
    ' >/dev/null \
  || die "Prometheus does not see the current exporter pod reporting bridge online"

prom_query \
  "mqtt_mqtt_connected{namespace=\"zigbee2mqtt\",pod=\"$exporter_pod\",topic=\"zigbee2mqtt_bridge_health\"}" \
  | jq -e '
      .status == "success" and
      (.data.result | length) == 1 and
      (.data.result[0].value[1] | tonumber) == 1
    ' >/dev/null \
  || die "Prometheus does not see the current exporter pod reporting MQTT connected"

prom_query \
  "time() - mqtt_response_time{namespace=\"zigbee2mqtt\",pod=\"$exporter_pod\",topic=\"zigbee2mqtt_bridge_health\"} / 1000" \
  | jq -e '
      .status == "success" and
      (.data.result | length) == 1 and
      ((.data.result[0].value[1] | tonumber) >= 0) and
      ((.data.result[0].value[1] | tonumber) < 180)
    ' >/dev/null \
  || die "Prometheus does not have Zigbee2MQTT health data newer than three minutes"

prom_query 'probe_success{instance="https://zigbee2mqtt.worm.run",service_tier="critical"}' \
  | jq -e '
      .status == "success" and
      (.data.result | length) == 1 and
      .data.result[0].metric.job == "blackbox-critical-ingress" and
      (.data.result[0].value[1] | tonumber) == 1
    ' >/dev/null \
  || die "the critical blackbox probe for https://zigbee2mqtt.worm.run is not successful"

prom_query 'probe_success{instance="slzb-mrw10u.iot.matrix:7638",service_tier="critical"}' \
  | jq -e '
      .status == "success" and
      (.data.result | length) == 1 and
      .data.result[0].metric.job == "blackbox-zigbee-coordinator" and
      .data.result[0].metric.probe_scope == "zigbee-coordinator" and
      (.data.result[0].value[1] | tonumber) == 1
    ' >/dev/null \
  || die "the critical TCP probe for slzb-mrw10u.iot.matrix:7638 is not successful"

curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/rules?type=alert" \
  >"$tmpdir/prometheus-alert-rules.json"
jq -e '
      [.data.groups[].rules[] |
        select(.name == "Zigbee2MQTTBridgeUnhealthy")] as $rules |
      ($rules | length) == 1 and
      $rules[0].health == "ok" and
      $rules[0].state == "inactive" and
      ($rules[0].lastError == null or $rules[0].lastError == "") and
      $rules[0].duration == 300
    ' "$tmpdir/prometheus-alert-rules.json" >/dev/null \
  || die "Zigbee2MQTTBridgeUnhealthy is missing, unhealthy, active, or has the wrong delay"
jq -e '
      [.data.groups[].rules[] |
        select(.name == "CriticalEndpointDown")] as $rules |
      ($rules | length) == 1 and
      $rules[0].health == "ok" and
      ($rules[0].lastError == null or $rules[0].lastError == "") and
      $rules[0].duration == 180 and
      ($rules[0].query | contains("probe_success{service_tier=\"critical\"} == 0"))
    ' "$tmpdir/prometheus-alert-rules.json" >/dev/null \
  || die "CriticalEndpointDown is missing, unhealthy, or has the wrong expression or delay"

curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/alerts" \
  >"$tmpdir/prometheus-alerts.json"
jq -e '
      [.data.alerts[] |
        select(.labels.alertname == "Zigbee2MQTTBridgeUnhealthy")] |
      length == 0
    ' "$tmpdir/prometheus-alerts.json" >/dev/null \
  || die "Zigbee2MQTTBridgeUnhealthy is unexpectedly pending or firing"
jq -e '
      [.data.alerts[] |
        select(
          .labels.alertname == "CriticalEndpointDown" and
          .labels.instance == "slzb-mrw10u.iot.matrix:7638"
        )] |
      length == 0
    ' "$tmpdir/prometheus-alerts.json" >/dev/null \
  || die "the Zigbee coordinator CriticalEndpointDown alert is unexpectedly pending or firing"

ok "Prometheus sees healthy ingress, coordinator TCP, and MQTT paths and evaluates both critical alerts cleanly"
ok "Zigbee2MQTT monitoring live validation complete"
