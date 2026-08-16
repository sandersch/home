#!/usr/bin/env bash
# Phase 1.1 - host-level camera isolation with nftables and IPv6 disabled on cam0.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools ip nft sysctl systemctl journalctl
assert_phase0_network_settled

step "Validate canonical nftables config before installing"
sudo nft -c -f "$HOST_ETC/nftables.conf" \
  || die "nftables syntax check failed for $HOST_ETC/nftables.conf"
ok "nftables syntax check passed"

step "Install nftables and camera IPv6 sysctl config"
install_file nftables.conf /etc/nftables.conf root:root 644
install_file sysctl.d/99-camera-no-ipv6.conf /etc/sysctl.d/99-camera-no-ipv6.conf root:root 644

step "Apply sysctl settings"
sudo sysctl --system >/dev/null
if [ "$(cat /proc/sys/net/ipv6/conf/cam0/disable_ipv6 2>/dev/null || printf 0)" = "1" ]; then
  ok "IPv6 disabled on cam0"
else
  die "IPv6 is not disabled on cam0 after sysctl --system"
fi

step "Enable and reload nftables"
sudo systemctl enable --now nftables
sudo systemctl reload nftables
service_active nftables

step "Confirm host isolation tables are loaded"
sudo nft list table inet camera_isolation
sudo nft list table inet frigate_access
sudo nft list table inet ups_access
ok "camera_isolation, frigate_access, and ups_access tables are active"

cat <<'EOF'

Next:
  - Run 02-camera-dhcp-ntp.sh.
  - Use 03-camera-segment-validation.sh with a test device on VLAN 105.

At this point, only the input chain is meaningfully testable. The forward chain
must be validated again after k3s enables net.ipv4.ip_forward in Phase 2.
EOF
