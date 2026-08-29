#!/usr/bin/env bash
# NFS exports 04 - validate the Prometheus probe, the homelab.nfs rules, and the
# node-exporter nfsd collector that both depend on.
#
# Optional:
#   NFS_PROMETHEUS_LOCAL_PORT=19091   local port used for the Prometheus port-forward
#   NFS_ALERT_DRILL=1                 stop nfs-server briefly to prove the alerts fire
# shellcheck source=runbooks/nfs-exports/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools curl jq kubectl kustomize yq seq

prometheus_port="${NFS_PROMETHEUS_LOCAL_PORT:-19091}"
alert_drill="${NFS_ALERT_DRILL:-0}"
[[ "$prometheus_port" =~ ^[0-9]+$ ]] && [ "$prometheus_port" -ge 1024 ] && [ "$prometheus_port" -le 65535 ] \
  || die "NFS_PROMETHEUS_LOCAL_PORT must be an unprivileged TCP port"
[[ "$alert_drill" =~ ^[01]$ ]] || die "NFS_ALERT_DRILL must be 0 or 1"

CONFIG_DIR="$REPO_ROOT/infrastructure/monitoring/configs"
tmpdir="$(mktemp -d /tmp/homelab-nfs-validate.XXXXXX)"
forward_pid=""
drill_started=0
cleanup() {
  if [ "$drill_started" -eq 1 ]; then
    warn "the alert drill started; make sure nfs-server is running again"
    sudo systemctl start nfs-server || true
  fi
  if [ -n "$forward_pid" ]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

prom_query() {
  curl --fail --silent --show-error --get \
    --data-urlencode "query=$1" \
    "http://127.0.0.1:$prometheus_port/api/v1/query"
}
query_value() { prom_query "$1" | jq -r '.data.result[0].value[1] // empty'; }

step "Verify rendered monitoring invariants"
yq -e '
  select(.kind == "Probe" and .metadata.name == "nfs") |
  .spec.module == "tcp_connect" and
  .spec.jobName == "blackbox-nfs" and
  (.spec.targets.staticConfig.static | index("10.137.20.5:2049") != null) and
  .spec.targets.staticConfig.labels.probe_scope == "nfs"
' "$CONFIG_DIR/blackbox-probes.yaml" >/dev/null \
  || die "the NFS blackbox probe target, module, or scope changed unexpectedly"
yq -e '
  select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
  any(.spec.groups[];
    .name == "homelab.nfs" and
    any(.rules[]; .alert == "NFSServerDown" and .for == "5m" and
      .labels.severity == "warning" and
      (.expr | contains("node_nfsd_server_threads == 0")) and
      (.expr | contains("absent") | not)) and
    any(.rules[]; .alert == "NFSLegacyVersionServed" and
      (.expr | contains("node_nfsd_requests_total{proto!=\"4\"}"))) and
    any(.rules[]; .alert == "NFSDCollectorFailing" and
      (.expr | contains("absent(node_scrape_collector_success{collector=\"nfsd\"})")) and
      (.expr | contains("node_scrape_collector_success{collector=\"nfsd\"} == 0")) and
      (.expr | contains("and on() probe_success{probe_scope=\"nfs\"} == 1"))))
' "$CONFIG_DIR/alert-rules.yaml" >/dev/null \
  || die "the homelab.nfs alert group changed unexpectedly"
kustomize build "$CONFIG_DIR" >/dev/null \
  || die "monitoring-configs no longer builds"
ok "the NFS probe and homelab.nfs rules render as expected"

step "Port-forward Prometheus"
kubectl -n monitoring port-forward service/kube-prometheus-stack-prometheus \
  "$prometheus_port:9090" >"$tmpdir/port-forward.log" 2>&1 &
forward_pid=$!
ready=0
for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:$prometheus_port/-/ready" >/dev/null 2>&1; then
    ready=1; break
  fi
  kill -0 "$forward_pid" 2>/dev/null || break
  sleep 1
done
[ "$ready" -eq 1 ] || { sed -n '1,60p' "$tmpdir/port-forward.log" >&2; die "Prometheus port-forward never became ready"; }
ok "Prometheus is reachable on 127.0.0.1:$prometheus_port"

step "Verify the nfsd collector and its metrics"
# The nfsd collector is on by default in node-exporter and reads the host's
# /proc/net/rpc/nfsd. Its series names have moved across releases, so assert the exact
# ones the homelab.nfs rules depend on rather than trusting the collector alone.
[ "$(query_value 'node_scrape_collector_success{collector="nfsd"}')" = "1" ] \
  || die "the node-exporter nfsd collector is not reporting success"
threads="$(query_value 'node_nfsd_server_threads')"
[ -n "$threads" ] || die "node_nfsd_server_threads is absent; the homelab.nfs rules cannot evaluate"
[ "${threads%%.*}" -gt 0 ] || die "node_nfsd_server_threads is $threads; nfsd has no running threads"
prom_query 'node_nfsd_requests_total' | jq -e '.data.result | length > 0' >/dev/null \
  || die "node_nfsd_requests_total is absent; NFSLegacyVersionServed would never fire"
prom_query 'node_nfsd_requests_total{proto!="4"}' \
  | jq -e '[.data.result[].value[1] | tonumber] | all(. == 0)' >/dev/null \
  || die "minis has already served pre-v4 requests; the NFSv4-only lockdown is not effective"
ok "nfsd collector is healthy, reports $threads threads, and has served no pre-v4 request"

step "Verify the blackbox probe target"
[ "$(query_value 'probe_success{probe_scope="nfs"}')" = "1" ] \
  || die "the NFS blackbox probe is not succeeding against 10.137.20.5:2049"
curl --fail --silent --show-error \
  "http://127.0.0.1:$prometheus_port/api/v1/rules?type=alert" \
  | jq -e '
      [.data.groups[] | select(.name == "homelab.nfs") | .rules[]
       | select(.health == "ok")] | length == 3
    ' >/dev/null \
  || die "the homelab.nfs rules are missing or unhealthy in Prometheus"
ok "Prometheus probes 2049 and evaluates all three homelab.nfs rules without errors"

if [ "$alert_drill" -eq 1 ]; then
  step "Run the NFSServerDown drill"
  confirm "Stop nfs-server for ~6 minutes? Remote clients will hang (they mount hard)." \
    || die "alert drill cancelled"
  require_sudo
  drill_started=1
  sudo systemctl stop nfs-server
  deadline=$((SECONDS + 480))
  state=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(curl --fail --silent "http://127.0.0.1:$prometheus_port/api/v1/alerts" \
      | jq -r '[.data.alerts[] | select(.labels.alertname == "NFSServerDown")][0].state // empty')"
    [ "$state" = "firing" ] && break
    sleep 10
  done
  [ "$state" = "firing" ] || die "NFSServerDown did not fire within eight minutes"
  ok "NFSServerDown is firing"
  confirm "Did the warning Pushover notification arrive?" \
    || warn "notification not confirmed; check the Alertmanager routing for severity=warning"
  sudo systemctl start nfs-server
  drill_started=0
  service_active nfs-server
  sudo exportfs -ra
  assert_nfs_export_options
  ok "nfs-server restarted and the exports are back"
  printf '%s\n' "StandardEndpointDown (the blackbox probe, 10m) resolves on its own schedule."
else
  warn "alert drill skipped; rerun with NFS_ALERT_DRILL=1 during a quiet window"
fi

ok "automated NFS monitoring validation complete"
