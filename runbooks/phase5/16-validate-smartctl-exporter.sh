#!/usr/bin/env bash
# Phase 5.16 - validate SMART telemetry for every disk, Prometheus discovery, the
# homelab.disks rules, and optionally run a Pushover delivery drill through a
# temporary PrometheusRule.
#
# Optional:
#   SMART_EXPORTER_LOCAL_PORT=19633   local port used for the exporter
#   SMART_PROMETHEUS_LOCAL_PORT=19090 local port used for Prometheus
#   SMART_ALERT_DRILL=1               enable the interactive Pushover drill; needs a
#                                     kubeconfig context that can create PrometheusRules

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools curl jq kubectl kustomize seq yq

exporter_port="${SMART_EXPORTER_LOCAL_PORT:-19633}"
prometheus_port="${SMART_PROMETHEUS_LOCAL_PORT:-19090}"
alert_drill="${SMART_ALERT_DRILL:-0}"
expected_devices=18

for port_spec in "SMART_EXPORTER_LOCAL_PORT:$exporter_port" "SMART_PROMETHEUS_LOCAL_PORT:$prometheus_port"; do
  port_name="${port_spec%%:*}"
  port_value="${port_spec##*:}"
  [[ "$port_value" =~ ^[0-9]+$ ]] && [ "$port_value" -ge 1024 ] && [ "$port_value" -le 65535 ] \
    || die "$port_name must be an unprivileged TCP port"
done
[ "$exporter_port" != "$prometheus_port" ] || die "exporter and Prometheus local ports must differ"
[[ "$alert_drill" =~ ^[01]$ ]] || die "SMART_ALERT_DRILL must be 0 or 1"

# The 15 md3 disks come from the migration SMART-test list; the other three are the
# blank SAS disks sdm and sdn and the NVMe, recorded in the 2026-10-17 baseline.
expected_serials=(ZC141NXL0000C814H7CH Z4F1DZAP 50026B73843A92E9)
while IFS= read -r serial; do
  expected_serials+=("$serial")
done < <(sed -n 's|^  /dev/disk/by-id/ata-.*_||p' \
  "$REPO_ROOT/runbooks/direct-attached-storage-migration/01-start-smart-tests.sh")
[ "${#expected_serials[@]}" -eq "$expected_devices" ] \
  || die "expected $expected_devices disk serials, derived ${#expected_serials[@]}"

tmpdir="$(mktemp -d /tmp/homelab-smartctl-validate.XXXXXX)"
exporter_forward_pid=""
prometheus_forward_pid=""
drill_rule_applied=0
cleanup() {
  if [ "$drill_rule_applied" -eq 1 ]; then
    kubectl -n monitoring delete prometheusrule smartctl-alert-drill --ignore-not-found >/dev/null 2>&1 \
      || warn "could not delete PrometheusRule monitoring/smartctl-alert-drill; remove it by hand"
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

drill_alert_state() {
  curl --fail --silent --show-error \
    "http://127.0.0.1:$prometheus_port/api/v1/alerts" \
    | jq -r '[.data.alerts[] | select(.labels.alertname == "SmartAlertDrill")][0].state // empty'
}

step "Verify rendered SMART monitoring invariants"
kustomize build "$PHASE5_OBSERVABILITY_CONFIG_DIR" >/dev/null
assert_phase5_smartctl_invariants
ok "smartctl-exporter manifests and homelab.disks rules match the reviewed configuration"

step "Verify deployed SMART monitoring resources"
kubectl -n monitoring rollout status daemonset/smartctl-exporter --timeout=300s
kubectl -n monitoring get service smartctl-exporter >/dev/null
kubectl -n monitoring get servicemonitor smartctl-exporter >/dev/null
kubectl -n monitoring get prometheusrule homelab-alerts >/dev/null
ok "smartctl-exporter workload, discovery, and alert resources exist"

step "Verify the exporter reads every disk"
kubectl -n monitoring port-forward service/smartctl-exporter "$exporter_port:9633" \
  >"$tmpdir/exporter-port-forward.log" 2>&1 &
exporter_forward_pid=$!
wait_for_http "http://127.0.0.1:$exporter_port/metrics" \
  "$tmpdir/exporter-port-forward.log" "$exporter_forward_pid"
curl --fail --silent --show-error \
  "http://127.0.0.1:$exporter_port/metrics" >"$tmpdir/metrics.txt"

grep -Fx "smartctl_devices $expected_devices" "$tmpdir/metrics.txt" >/dev/null \
  || die "smartctl-exporter does not report exactly $expected_devices devices"
for serial in "${expected_serials[@]}"; do
  grep '^smartctl_device{' "$tmpdir/metrics.txt" | grep -F "serial_number=\"$serial\"" >/dev/null \
    || die "no SMART data for disk serial $serial"
done
[ "$(grep -c '^smartctl_device_smart_status{' "$tmpdir/metrics.txt")" -eq "$expected_devices" ] \
  || die "not every device reports a SMART overall-health status"
if grep '^smartctl_device_smart_status{' "$tmpdir/metrics.txt" | grep -v ' 1$' >&2; then
  die "one or more devices fail the SMART overall-health self-assessment"
fi
[ "$(grep '^smartctl_device_attribute{' "$tmpdir/metrics.txt" \
  | grep 'attribute_name="Reallocated_Sector_Ct"' | grep -c 'attribute_value_type="raw"')" -eq 15 ] \
  || die "the 15 SATA disks do not all expose raw ATA attributes through the HBA"
grep -E '^smartctl_device_percentage_used\{device="nvme0"\} [0-9]+$' "$tmpdir/metrics.txt" >/dev/null \
  || die "the NVMe does not report percentage_used"
ok "all $expected_devices disks report healthy SMART data, with ATA attributes behind the HBA"

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
        select(.labels.job == "smartctl-exporter" and
          .labels.instance == "minis" and
          .health == "up" and .lastError == "")] |
      length == 1
    ' >/dev/null \
  || die "Prometheus does not have exactly one healthy smartctl-exporter target on minis"
# Rules report health "unknown" until their first evaluation, so a run straight after a
# reconcile waits for one before judging them.
deadline=$((SECONDS + 180))
until curl --fail --silent --show-error \
    "http://127.0.0.1:$prometheus_port/api/v1/rules?type=alert" >"$tmpdir/rules.json" \
  && jq -e '
    [.data.groups[] | select(.name == "homelab.disks") | .rules[]] as $rules |
    ($rules | length) == 9 and
    all($rules[]; .health == "ok" and .state == "inactive")
  ' "$tmpdir/rules.json" >/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || die "homelab.disks rules are missing, unhealthy, pending, or firing; inspect Prometheus /alerts"
  sleep 10
done
ok "Prometheus scrapes smartctl-exporter and every homelab.disks rule is healthy and quiet"

if [ "$alert_drill" -eq 1 ]; then
  step "Run the SMART Pushover delivery drill"
  cat <<'EOF'
This applies a temporary PrometheusRule that fires a warning while the NVMe reports any
temperature, waits for a Pushover notification, and then deletes the rule. Flux does
not manage it, so it is removed on exit even if the drill is interrupted.
EOF
  confirm "Apply the temporary SmartAlertDrill rule?" || die "SMART alert drill cancelled"
  drill_rule_applied=1
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: smartctl-alert-drill
  namespace: monitoring
spec:
  groups:
    - name: homelab.disks.drill
      rules:
        - alert: SmartAlertDrill
          expr: |
            max by (instance, device, model_name, serial_number) (
              smartctl_device_temperature{temperature_type="current",device="nvme0"}
              * on (namespace, pod, device) group_left(model_name, serial_number)
              smartctl_device
            ) > 0
          for: 1m
          labels:
            severity: warning
          annotations:
            description: "Drill: {{ $labels.device }} (serial {{ $labels.serial_number }}) reports {{ $value }} C. Delete PrometheusRule monitoring/smartctl-alert-drill if this persists."
            summary: SMART alert delivery drill
EOF

  deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(drill_alert_state)" = "firing" ] && break
    sleep 5
  done
  [ "$(drill_alert_state)" = "firing" ] \
    || die "SmartAlertDrill did not reach firing state within five minutes"
  ok "SmartAlertDrill is firing"
  confirm "Did the warning Pushover notification arrive?" \
    || die "SMART drill Pushover notification was not confirmed"

  kubectl -n monitoring delete prometheusrule smartctl-alert-drill >/dev/null
  drill_rule_applied=0
  deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -z "$(drill_alert_state)" ] && break
    sleep 5
  done
  [ -z "$(drill_alert_state)" ] || die "SmartAlertDrill did not clear after its rule was deleted"
  ok "SmartAlertDrill rule removed and alert cleared"
  printf '%s\n' \
    "The resolved Pushover notification inherits Alertmanager's five-minute group interval." \
    "Confirm it arrives."
else
  warn "Pushover drill skipped; rerun with SMART_ALERT_DRILL=1 when an operator is present"
fi

ok "automated smartctl-exporter validation complete"
