#!/usr/bin/env bash
# Phase 5.13 - validate NUT telemetry, Prometheus discovery, the Grafana dashboard,
# and optionally perform a controlled UPS mains-loss notification drill.
#
# Optional:
#   NUT_EXPORTER_LOCAL_PORT=19199   local port used for the exporter
#   NUT_PROMETHEUS_LOCAL_PORT=19090 local port used for Prometheus
#   NUT_GRAFANA_URL=https://grafana.worm.run
#   NUT_POWER_DRILL=1               enable the interactive physical power drill

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools base64 curl jq kubectl kustomize seq yq

exporter_port="${NUT_EXPORTER_LOCAL_PORT:-19199}"
prometheus_port="${NUT_PROMETHEUS_LOCAL_PORT:-19090}"
grafana_url="${NUT_GRAFANA_URL:-https://grafana.worm.run}"
power_drill="${NUT_POWER_DRILL:-0}"

for port_spec in "NUT_EXPORTER_LOCAL_PORT:$exporter_port" "NUT_PROMETHEUS_LOCAL_PORT:$prometheus_port"; do
  port_name="${port_spec%%:*}"
  port_value="${port_spec##*:}"
  [[ "$port_value" =~ ^[0-9]+$ ]] && [ "$port_value" -ge 1024 ] && [ "$port_value" -le 65535 ] \
    || die "$port_name must be an unprivileged TCP port"
done
[ "$exporter_port" != "$prometheus_port" ] || die "exporter and Prometheus local ports must differ"
[[ "$power_drill" =~ ^[01]$ ]] || die "NUT_POWER_DRILL must be 0 or 1"
[[ "$grafana_url" == https://* ]] || die "NUT_GRAFANA_URL must use HTTPS"

tmpdir="$(mktemp -d /tmp/homelab-nut-validate.XXXXXX)"
exporter_forward_pid=""
prometheus_forward_pid=""
power_drill_started=0
cleanup() {
  if [ "$power_drill_started" -eq 1 ]; then
    warn "the power drill started; make sure the UPS mains input is reconnected"
  fi
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

query_value() {
  local query="$1"
  prom_query "$query" | jq -r '.data.result[0].value[1] // empty'
}

wait_for_query_value() {
  local query="$1" expected="$2" timeout_seconds="$3" description="$4"
  local deadline value
  deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    value="$(query_value "$query")"
    if [ "$value" = "$expected" ]; then
      ok "$description"
      return 0
    fi
    sleep 5
  done
  die "timed out waiting for $description"
}

alert_state() {
  curl --fail --silent --show-error \
    "http://127.0.0.1:$prometheus_port/api/v1/alerts" \
    | jq -r '[.data.alerts[] | select(.labels.alertname == "UPSOnBattery")][0].state // empty'
}

step "Verify rendered NUT monitoring invariants"
assert_phase5_observability_builds
assert_phase5_observability_invariants

step "Verify deployed NUT monitoring resources"
kubectl -n monitoring rollout status deploy/nut-exporter --timeout=300s
kubectl -n monitoring get service nut-exporter >/dev/null
kubectl -n monitoring get servicemonitor nut-exporter >/dev/null
kubectl -n monitoring get prometheusrule homelab-alerts >/dev/null
kubectl -n monitoring get configmap nut-exporter-dashboard >/dev/null
ok "nut-exporter workload, discovery, alert, and dashboard resources exist"

step "Verify the exporter can read cp1500"
kubectl -n monitoring port-forward service/nut-exporter "$exporter_port:9199" \
  >"$tmpdir/exporter-port-forward.log" 2>&1 &
exporter_forward_pid=$!
wait_for_http "http://127.0.0.1:$exporter_port/metrics" \
  "$tmpdir/exporter-port-forward.log" "$exporter_forward_pid"
curl --fail --silent --show-error \
  "http://127.0.0.1:$exporter_port/ups_metrics?ups=cp1500" \
  >"$tmpdir/ups-metrics.txt"

for metric in \
  network_ups_tools_battery_charge \
  network_ups_tools_battery_runtime \
  network_ups_tools_input_voltage \
  network_ups_tools_output_voltage \
  network_ups_tools_ups_load; do
  grep -E "^${metric} [-+]?[0-9]+([.][0-9]+)?$" \
    "$tmpdir/ups-metrics.txt" >/dev/null \
    || die "$metric is missing for cp1500"
done
grep '^network_ups_tools_ups_status{' "$tmpdir/ups-metrics.txt" \
  | grep 'flag="OL"' | grep -E ' 1$' >/dev/null \
  || die "cp1500 is not reporting OL=1"
grep '^network_ups_tools_ups_status{' "$tmpdir/ups-metrics.txt" \
  | grep 'flag="OB"' | grep -E ' 0$' >/dev/null \
  || die "cp1500 is not reporting OB=0"
ok "cp1500 reports online status, charge, runtime, load, and voltage telemetry"

step "Verify Prometheus target and rule health"
kubectl -n monitoring port-forward service/kube-prometheus-stack-prometheus \
  "$prometheus_port:9090" >"$tmpdir/prometheus-port-forward.log" 2>&1 &
prometheus_forward_pid=$!
wait_for_http "http://127.0.0.1:$prometheus_port/-/ready" \
  "$tmpdir/prometheus-port-forward.log" "$prometheus_forward_pid"
curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/targets?state=active" \
  | jq -e '
      [.data.activeTargets[] |
        select((.scrapeUrl | contains("nut-exporter")) and
          .health == "up" and .lastError == "")] |
      length == 1
    ' >/dev/null \
  || die "Prometheus does not have exactly one healthy nut-exporter target"
curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/rules?type=alert" \
  | jq -e '
      any(.data.groups[].rules[];
        .name == "UPSOnBattery" and .health == "ok")
    ' >/dev/null \
  || die "UPSOnBattery is missing or unhealthy in Prometheus"
[ "$(query_value 'network_ups_tools_ups_status{ups="cp1500",flag="OB"}')" = "0" ] \
  || die "Prometheus does not currently see cp1500 as online"
ok "Prometheus scrapes nut-exporter and evaluates UPSOnBattery without errors"

step "Verify Grafana provisioned the UPS dashboard"
grafana_secret="$(kubectl -n monitoring get secret grafana-admin -o json)"
grafana_user="$(
  printf '%s' "$grafana_secret" \
    | jq -r '.data["admin-user"]' | base64 --decode
)"
grafana_password="$(
  printf '%s' "$grafana_secret" \
    | jq -r '.data["admin-password"]' | base64 --decode
)"
[ -n "$grafana_user" ] && [ -n "$grafana_password" ] \
  || die "could not read deployed Grafana administrator credentials"
curl --fail --silent --show-error \
  --user "$grafana_user:$grafana_password" \
  "$grafana_url/api/dashboards/uid/nut-exporter" \
  | jq -e '.dashboard.uid == "nut-exporter" and .dashboard.title == "UPS / NUT — CP1500"' \
    >/dev/null \
  || die "Grafana has not provisioned the UPS dashboard"
unset grafana_secret grafana_user grafana_password
ok "Grafana serves the UPS / NUT — CP1500 dashboard"

if [ "$power_drill" -eq 1 ]; then
  step "Run the controlled UPS mains-loss drill"
  cat <<'EOF'
Disconnect only the UPS mains input. Keep the protected load connected to the UPS.
Do not continue if the displayed runtime is too short to complete this drill safely.
EOF
  confirm "Start the physical mains-loss drill?" || die "UPS power drill cancelled"
  power_drill_started=1
  confirm "Is the UPS mains input disconnected while the protected load remains powered?" \
    || die "UPS power drill cancelled before disconnect confirmation"
  wait_for_query_value \
    'network_ups_tools_ups_status{ups="cp1500",flag="OB"}' "1" 90 \
    "Prometheus sees cp1500 on battery"

  deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(alert_state)" = "firing" ] && break
    sleep 5
  done
  [ "$(alert_state)" = "firing" ] \
    || die "UPSOnBattery did not reach firing state within three minutes"
  ok "UPSOnBattery is firing"
  confirm "Did the critical Pushover notification arrive?" \
    || die "critical UPS Pushover notification was not confirmed"

  confirm "Reconnect the UPS mains input, then confirm here" \
    || die "reconnect the UPS mains input before leaving the drill"
  power_drill_started=0
  wait_for_query_value \
    'network_ups_tools_ups_status{ups="cp1500",flag="OB"}' "0" 90 \
    "Prometheus sees cp1500 back online"

  deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -z "$(alert_state)" ] && break
    sleep 5
  done
  [ -z "$(alert_state)" ] || die "UPSOnBattery did not resolve after mains returned"
  ok "UPSOnBattery resolved"
  printf '%s\n' \
    "The quiet Pushover recovery inherits Alertmanager's five-minute group interval." \
    "Confirm it arrives, and confirm Dead Man's Snitch remains healthy."
else
  warn "physical mains-loss drill skipped; rerun with NUT_POWER_DRILL=1 when an operator is present"
fi

ok "automated nut-exporter validation complete"
