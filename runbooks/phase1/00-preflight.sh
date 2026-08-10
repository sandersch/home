#!/usr/bin/env bash
# Phase 1 preflight - read-only checks before applying camera isolation.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Phase 1 preflight checks"

require_not_root
require_sudo
require_host_etc
require_tools ip systemctl nft sysctl dnsmasq chronyc journalctl timeout findmnt
assert_phase1_source_files
assert_phase0_network_settled

step "Verify required packages are installed"
dpkg -s nftables dnsmasq chrony >/dev/null 2>&1 \
  || die "nftables, dnsmasq, and chrony must be installed by Phase 0.3"
ok "nftables, dnsmasq, and chrony packages are installed"

step "Check current service posture"
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq; then
  warn "dnsmasq is already enabled or active; 02-camera-dhcp-ntp.sh will replace/restart it with the canonical camera config"
else
  ok "dnsmasq is not active yet, as expected before Phase 1.2"
fi

if systemctl is-active --quiet chrony; then
  ok "chrony is already active"
else
  warn "chrony is not active yet; 02-camera-dhcp-ntp.sh will enable it"
fi

step "Preflight complete"
cat <<'EOF'
Run the Phase 1 steps in order:
  01-host-isolation.sh          nftables + camera IPv6 sysctl
  02-camera-dhcp-ntp.sh         dnsmasq DHCP-only + chrony NTP
  catalyst-camera-isolation.md  switch-side protected-port validation
  03-camera-segment-validation.sh
  04-direct-storage-throughput.sh

The forward-chain drop must be re-tested after k3s flips ip_forward=1 in Phase 2.
EOF
