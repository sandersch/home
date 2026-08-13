#!/usr/bin/env bash
# Phase 5.14 - audit current reservations and historical resource use for the
# deployed application namespaces.
#
# Optional:
#   RESOURCE_AUDIT_WINDOW=14d       Prometheus lookback window
#   RESOURCE_AUDIT_LOCAL_PORT=19090 local port used for Prometheus

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools curl jq kubectl seq

window="${RESOURCE_AUDIT_WINDOW:-14d}"
prometheus_port="${RESOURCE_AUDIT_LOCAL_PORT:-19090}"
namespace_matcher='media|frigate|home-assistant|mqtt'

[[ "$window" =~ ^[1-9][0-9]*(ms|s|m|h|d|w|y)$ ]] \
  || die "RESOURCE_AUDIT_WINDOW must be a positive Prometheus duration such as 7d or 14d"
[[ "$prometheus_port" =~ ^[0-9]+$ ]] \
  && [ "$prometheus_port" -ge 1024 ] \
  && [ "$prometheus_port" -le 65535 ] \
  || die "RESOURCE_AUDIT_LOCAL_PORT must be an unprivileged TCP port"

tmpdir="$(mktemp -d /tmp/homelab-resource-audit.XXXXXX)"
prometheus_forward_pid=""
cleanup() {
  if [ -n "$prometheus_forward_pid" ]; then
    kill "$prometheus_forward_pid" 2>/dev/null || true
    wait "$prometheus_forward_pid" 2>/dev/null || true
  fi
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
    die "Prometheus port-forward did not become ready at $url"
  fi
}

prom_query() {
  local name="$1" query="$2" output="$tmpdir/$1.json"
  if ! curl --fail --silent --show-error --get \
    --data-urlencode "query=$query" \
    "http://127.0.0.1:$prometheus_port/api/v1/query" >"$output"; then
    die "Prometheus query failed: $name"
  fi
  jq -e '.status == "success" and (.data.result | type == "array")' "$output" >/dev/null \
    || die "Prometheus returned an invalid response: $name"
  [ "$(jq '.data.result | length' "$output")" -gt 0 ] \
    || die "Prometheus returned no metrics: $name"
}

active_phase="max by (namespace, pod) (
  kube_pod_status_phase{namespace=~\"$namespace_matcher\",phase=~\"Pending|Running\"} == 1
)"

step "Open a temporary Prometheus port-forward" >&2
kubectl -n monitoring port-forward service/kube-prometheus-stack-prometheus \
  "$prometheus_port:9090" >"$tmpdir/prometheus-port-forward.log" 2>&1 &
prometheus_forward_pid=$!
wait_for_http "http://127.0.0.1:$prometheus_port/-/ready" \
  "$tmpdir/prometheus-port-forward.log" "$prometheus_forward_pid"
ok "Prometheus is ready on local port $prometheus_port" >&2

step "Query current reservations and $window of resource history" >&2
prom_query tracked "sum by (namespace, container) (
  kube_pod_container_info{namespace=~\"$namespace_matcher\"}
  * on (namespace, pod) group_left() ($active_phase)
)"
prom_query cpu_requests "sum by (namespace, container) (
  kube_pod_container_resource_requests{namespace=~\"$namespace_matcher\",resource=\"cpu\",unit=\"core\"}
  * on (namespace, pod) group_left() ($active_phase)
)"
prom_query cpu_limits "sum by (namespace, container) (
  kube_pod_container_resource_limits{namespace=~\"$namespace_matcher\",resource=\"cpu\",unit=\"core\"}
  * on (namespace, pod) group_left() ($active_phase)
)"
prom_query memory_requests "sum by (namespace, container) (
  kube_pod_container_resource_requests{namespace=~\"$namespace_matcher\",resource=\"memory\",unit=\"byte\"}
  * on (namespace, pod) group_left() ($active_phase)
)"
prom_query memory_limits "sum by (namespace, container) (
  kube_pod_container_resource_limits{namespace=~\"$namespace_matcher\",resource=\"memory\",unit=\"byte\"}
  * on (namespace, pod) group_left() ($active_phase)
)"
prom_query cpu_p95 "quantile_over_time(0.95,
  (sum by (namespace, container) (
    rate(container_cpu_usage_seconds_total{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}[5m])
  ))[$window:5m]
)"
prom_query cpu_max "max_over_time(
  (sum by (namespace, container) (
    rate(container_cpu_usage_seconds_total{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}[5m])
  ))[$window:5m]
)"
prom_query cpu_throttling "100 *
  sum by (namespace, container) (
    increase(container_cpu_cfs_throttled_periods_total{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}[$window])
  )
  / clamp_min(
    sum by (namespace, container) (
      increase(container_cpu_cfs_periods_total{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}[$window])
    ), 1
  )"
prom_query memory_p95 "quantile_over_time(0.95,
  (sum by (namespace, container) (
    container_memory_working_set_bytes{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}
  ))[$window:5m]
)"
prom_query memory_max "max_over_time(
  (sum by (namespace, container) (
    container_memory_working_set_bytes{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}
  ))[$window:5m]
)"
prom_query oom_events "sum by (namespace, container) (
  increase(container_oom_events_total{namespace=~\"$namespace_matcher\",container!=\"\",image!=\"\"}[$window])
)"
ok "all Prometheus queries returned metrics" >&2

step "Render stable TSV and verify every tracked container joined" >&2
jq -nr \
  --slurpfile tracked "$tmpdir/tracked.json" \
  --slurpfile cpu_requests "$tmpdir/cpu_requests.json" \
  --slurpfile cpu_limits "$tmpdir/cpu_limits.json" \
  --slurpfile memory_requests "$tmpdir/memory_requests.json" \
  --slurpfile memory_limits "$tmpdir/memory_limits.json" \
  --slurpfile cpu_p95 "$tmpdir/cpu_p95.json" \
  --slurpfile cpu_max "$tmpdir/cpu_max.json" \
  --slurpfile cpu_throttling "$tmpdir/cpu_throttling.json" \
  --slurpfile memory_p95 "$tmpdir/memory_p95.json" \
  --slurpfile memory_max "$tmpdir/memory_max.json" \
  --slurpfile oom_events "$tmpdir/oom_events.json" '
    def result_map($response):
      reduce $response[0].data.result[] as $row ({};
        .[$row.metric.namespace + "\u0000" + $row.metric.container] =
          ($row.value[1] | tonumber));
    def rounded($scale):
      (. * $scale | round) / $scale;
    result_map($tracked) as $tracked_map |
    result_map($cpu_requests) as $cpu_request_map |
    result_map($cpu_limits) as $cpu_limit_map |
    result_map($memory_requests) as $memory_request_map |
    result_map($memory_limits) as $memory_limit_map |
    result_map($cpu_p95) as $cpu_p95_map |
    result_map($cpu_max) as $cpu_max_map |
    result_map($cpu_throttling) as $cpu_throttling_map |
    result_map($memory_p95) as $memory_p95_map |
    result_map($memory_max) as $memory_max_map |
    result_map($oom_events) as $oom_event_map |
    ($tracked_map | keys | sort) as $keys |
    [$cpu_request_map, $cpu_limit_map, $memory_request_map, $memory_limit_map,
      $cpu_p95_map, $cpu_max_map, $cpu_throttling_map, $memory_p95_map,
      $memory_max_map, $oom_event_map] as $required_maps |
    ([$keys[] as $key |
      $required_maps[] | select(has($key) | not) | $key][0] // null) as $missing |
    if $missing != null then
      error("missing Prometheus data for tracked container " +
        ($missing | gsub("\u0000"; "/")))
    else
      (["NAMESPACE", "CONTAINER", "CPU_REQUEST_CORES", "CPU_LIMIT_CORES",
        "MEMORY_REQUEST_MIB", "MEMORY_LIMIT_MIB", "CPU_5M_P95_CORES",
        "CPU_5M_MAX_CORES", "CPU_THROTTLING_PCT", "MEMORY_WS_P95_MIB",
        "MEMORY_WS_MAX_MIB", "OOM_EVENTS"] | @tsv),
      ($keys[] as $key |
        ($key | split("\u0000")) as $identity |
        [$identity[0], $identity[1],
          ($cpu_request_map[$key] | rounded(1000000)),
          ($cpu_limit_map[$key] | rounded(1000000)),
          ($memory_request_map[$key] / 1048576 | rounded(1000)),
          ($memory_limit_map[$key] / 1048576 | rounded(1000)),
          ($cpu_p95_map[$key] | rounded(1000000)),
          ($cpu_max_map[$key] | rounded(1000000)),
          ($cpu_throttling_map[$key] | rounded(1000)),
          ($memory_p95_map[$key] / 1048576 | rounded(1000)),
          ($memory_max_map[$key] / 1048576 | rounded(1000)),
          ($oom_event_map[$key] | rounded(1000))] | @tsv),
      (($keys | map(split("\u0000")[0]) | unique)[] as $namespace |
        [$namespace, "__TOTAL__",
          ([$keys[] | select(startswith($namespace + "\u0000")) |
            $cpu_request_map[.]] | add | rounded(1000000)),
          ([$keys[] | select(startswith($namespace + "\u0000")) |
            $cpu_limit_map[.]] | add | rounded(1000000)),
          ([$keys[] | select(startswith($namespace + "\u0000")) |
            $memory_request_map[.]] | add / 1048576 | rounded(1000)),
          ([$keys[] | select(startswith($namespace + "\u0000")) |
            $memory_limit_map[.]] | add / 1048576 | rounded(1000)),
          "", "", "", "", "", ""] | @tsv)
    end
  ' || die "resource audit could not join all tracked containers"
ok "resource audit complete; thresholds are observational" >&2
