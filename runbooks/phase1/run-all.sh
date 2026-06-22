#!/usr/bin/env bash
# Run the host-side Phase 1 steps in dependency order.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STEPS=(
  00-preflight.sh
  01-host-isolation.sh
  02-camera-dhcp-ntp.sh
)

step "Phase 1 - host-side run (${#STEPS[@]} steps)"
cat <<'EOF'
This applies host networking services only. It does not configure the Catalyst
switch, and it does not replace the external validation steps that require a
test device on the camera segment.
EOF
confirm "Run the host-side Phase 1 steps now?" || die "aborted"

for s in "${STEPS[@]}"; do
  step "=== $s ==="
  bash "$PHASE1_LIB_DIR/$s"
done

step "Phase 1 host-side steps complete"
cat <<'EOF'
Remaining Phase 1 work:
  - Complete/confirm catalyst-camera-isolation.md before connecting real cameras.
  - Run 03-camera-segment-validation.sh with a test device on VLAN 105.
  - Run 04-nas-throughput.sh with iperf3 server running on the NAS.
  - After Phase 2/k3s, re-test camera forwarding with gateway 192.168.105.1.
EOF
