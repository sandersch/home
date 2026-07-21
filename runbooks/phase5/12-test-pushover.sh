#!/usr/bin/env bash
# Phase 5.12 - send and resolve synthetic warning/critical alerts through Alertmanager.
#
# Optional:
#   PUSHOVER_TEST_CONFIRM=1          skip the interactive confirmation
#   PUSHOVER_TEST_LOCAL_PORT=19093   local port used for kubectl port-forward
#   PUSHOVER_TEST_FIRE_WAIT=45       seconds before resolving the alerts
#   PUSHOVER_TEST_RESOLVE_WAIT=330   seconds to allow for the 5m group interval

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools curl date jq kubectl kustomize seq yq

local_port="${PUSHOVER_TEST_LOCAL_PORT:-19093}"
fire_wait="${PUSHOVER_TEST_FIRE_WAIT:-45}"
resolve_wait="${PUSHOVER_TEST_RESOLVE_WAIT:-330}"
[[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1024 ] && [ "$local_port" -le 65535 ] \
  || die "PUSHOVER_TEST_LOCAL_PORT must be an unprivileged TCP port"
[[ "$fire_wait" =~ ^[0-9]+$ ]] || die "PUSHOVER_TEST_FIRE_WAIT must be a number of seconds"
[[ "$resolve_wait" =~ ^[0-9]+$ ]] || die "PUSHOVER_TEST_RESOLVE_WAIT must be a number of seconds"

tmpdir="$(mktemp -d /tmp/homelab-pushover-test.XXXXXX)"
port_forward_pid=""
cleanup() {
  if [ -n "$port_forward_pid" ]; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

assert_phase5_pushover_invariants "$tmpdir/pushover-rendered.yaml"
[ -f "$PHASE5_PUSHOVER_SECRET" ] \
  || die "Pushover is dormant; run 11-setup-pushover.sh and reconcile it first"
kubectl -n monitoring get alertmanagerconfig pushover >/dev/null \
  || die "AlertmanagerConfig/monitoring/pushover is not present on the cluster"
kubectl -n monitoring get secret pushover >/dev/null \
  || die "Secret/monitoring/pushover is not present on the cluster"

if [ "${PUSHOVER_TEST_CONFIRM:-0}" != "1" ]; then
  confirm "Send synthetic warning and critical phone notifications?" \
    || die "Pushover notification test cancelled"
fi

step "Open a local tunnel to Alertmanager"
kubectl -n monitoring port-forward \
  service/kube-prometheus-stack-alertmanager "$local_port:9093" \
  >"$tmpdir/port-forward.log" 2>&1 &
port_forward_pid=$!

alertmanager_url="http://127.0.0.1:$local_port"
ready=0
for _ in $(seq 1 20); do
  if curl --fail --silent --show-error "$alertmanager_url/-/ready" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$port_forward_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  sed -n '1,120p' "$tmpdir/port-forward.log" >&2
  die "Alertmanager port-forward did not become ready"
fi
ok "Alertmanager is reachable at $alertmanager_url"

starts_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
safety_end="$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ)"

write_payload() {
  local ends_at="$1" output="$2"
  jq -n \
    --arg startsAt "$starts_at" \
    --arg endsAt "$ends_at" \
    '[
      {
        labels: {
          alertname: "PushoverSyntheticWarning",
          severity: "warning",
          namespace: "monitoring",
          instance: "phase5-pushover-test"
        },
        annotations: {
          summary: "Synthetic Pushover warning",
          description: "Manual Alertmanager notification drill; no service is degraded."
        },
        startsAt: $startsAt,
        endsAt: $endsAt,
        generatorURL: "https://grafana.worm.run"
      },
      {
        labels: {
          alertname: "PushoverSyntheticCritical",
          severity: "critical",
          namespace: "monitoring",
          instance: "phase5-pushover-test"
        },
        annotations: {
          summary: "Synthetic Pushover critical alert",
          description: "Manual Alertmanager notification drill; no service is degraded."
        },
        startsAt: $startsAt,
        endsAt: $endsAt,
        generatorURL: "https://grafana.worm.run"
      }
    ]' >"$output"
}

step "Inject synthetic warning and critical alerts"
write_payload "$safety_end" "$tmpdir/firing.json"
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data-binary "@$tmpdir/firing.json" \
  "$alertmanager_url/api/v2/alerts"
ok "synthetic alerts submitted; the 30-second group wait is active"
printf '%s\n' \
  "Expect one ordinary-priority warning and one high-priority critical notification." \
  "The critical notification must not request acknowledgement or repeat like emergency priority 2."
sleep "$fire_wait"

step "Resolve both synthetic alerts"
resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_payload "$resolved_at" "$tmpdir/resolved.json"
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data-binary "@$tmpdir/resolved.json" \
  "$alertmanager_url/api/v2/alerts"
ok "synthetic resolutions submitted"

if [ "$resolve_wait" -gt 0 ]; then
  printf 'Waiting %s seconds for the inherited 5-minute group interval...\n' "$resolve_wait"
  sleep "$resolve_wait"
fi

ok "Pushover drill complete"
printf '%s\n' \
  "Confirm both quiet low-priority recovery notifications arrived, Watchdog never appeared in Pushover," \
  "and the Dead Man's Snitch check remains healthy."
