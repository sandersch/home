#!/usr/bin/env bash
# Phase 4 validation - check Z-Wave JS UI and its Home Assistant connection path.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify Z-Wave JS UI rollout and storage"
kubectl -n home-assistant rollout status deploy/zwave-js-ui --timeout=300s
kubectl -n home-assistant get pvc zwave-js-ui-store-pvc
ok "Z-Wave JS UI rollout and retained store are ready"

step "Verify Z-Wave JS UI scheduling and controller configuration"
zwave_priority="$(kubectl -n home-assistant get deploy zwave-js-ui -o jsonpath='{.spec.template.spec.priorityClassName}')"
zwave_port="$(kubectl -n home-assistant get deploy zwave-js-ui -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ZWAVE_PORT")].value}')"
[ "$zwave_priority" = "homelab-critical" ] \
  || die "expected priorityClassName=homelab-critical, got '${zwave_priority:-unset}'"
[ "$zwave_port" = "tcp://slzb-mrw10u.iot.matrix:6638" ] \
  || die "unexpected ZWAVE_PORT '${zwave_port:-unset}'"
ok "Z-Wave JS UI uses the critical priority class and the network controller endpoint"

step "Verify the controller is reachable from Z-Wave JS UI"
kubectl -n home-assistant exec deploy/zwave-js-ui -- node -e \
  'const n=require("net"); const s=n.createConnection({host:"slzb-mrw10u.iot.matrix",port:6638}); s.setTimeout(5000); s.on("connect",()=>{s.end(); process.exit(0)}); s.on("timeout",()=>process.exit(1)); s.on("error",()=>process.exit(1))'
ok "SLZB-MRW10U serial-over-TCP endpoint is reachable"

step "Verify the cluster-internal UI service"
kubectl -n home-assistant exec deploy/home-assistant -- python3 -c \
  'import urllib.request; urllib.request.urlopen("http://zwave-js-ui:8091/", timeout=5).read(1)'
ok "Z-Wave JS UI responded through its Kubernetes Service"

if kubectl -n home-assistant exec deploy/zwave-js-ui -- node -e \
  'const n=require("net"); const s=n.createConnection({host:"127.0.0.1",port:3000}); s.setTimeout(3000); s.on("connect",()=>{s.end(); process.exit(0)}); s.on("timeout",()=>process.exit(1)); s.on("error",()=>process.exit(1))'; then
  ok "Z-Wave JS WebSocket server is listening on port 3000"
else
  warn "Z-Wave JS WebSocket server is not listening; enable it under Settings -> Home Assistant"
fi

cat <<'EOF'

Manual validation still required:
- Port-forward svc/zwave-js-ui:8091 and confirm the controller is connected.
- Back up all generated S0/S2 keys outside the cluster.
- Add Home Assistant's Z-Wave integration with:
  ws://zwave-js-ui.home-assistant.svc.cluster.local:3000
- Include a device and confirm its entities and controls work in Home Assistant.
EOF
