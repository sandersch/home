#!/usr/bin/env bash
# Run the Phase 0 steps in dependency order. Several steps are interactive
# (SSH restart, netplan apply, NUT password) and pause for confirmation — run this
# attached to a TTY, and keep a second SSH session open across the SSH/network steps.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEPS=(
  00-preflight.sh
  01-hostname-ssh.sh
  02-networking.sh
  03-system-prep.sh
  04-nfs-mounts.sh
  05-ups-nut.sh
  06-coral-udev.sh
)

step "Phase 0 — full run (${#STEPS[@]} steps)"
warn "01 restarts sshd and 02 reconfigures the network — keep a second session open."
confirm "Run all Phase 0 steps now?" || die "aborted"

for s in "${STEPS[@]}"; do
  step "=== $s ==="
  if [ "$s" = "02-networking.sh" ]; then
    PHASE0_REQUIRE_NETPLAN_APPLY=1 bash "$PHASE_DIR/$s"
  else
    bash "$PHASE_DIR/$s"
  fi
done

step "Phase 0 scripted steps complete"
cat <<'EOF'
  Remaining manual / off-host items:
    - 0.7 Router DNS: add wildcard *.worm.run -> 10.137.20.10 on the router.
    - Reboot once so the lan0/cam0 rename takes effect, then re-confirm addressing.
  Next: Phase 1 (camera-segment isolation) — see docs/build-plan.md.
EOF
