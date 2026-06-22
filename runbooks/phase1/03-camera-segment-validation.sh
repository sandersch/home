#!/usr/bin/env bash
# Phase 1 validation - tests that require a device attached to the camera segment.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools ip systemctl journalctl python3
assert_phase0_network_settled

step "Verify host-side services before external tests"
service_active nftables
service_active dnsmasq
service_active chrony
sudo nft list table inet camera_isolation >/dev/null \
  || die "camera_isolation nftables table is not loaded"
ok "host-side isolation services are ready"

cat <<'EOF'

Attach a test laptop or temporary test device to a protected camera port on VLAN 105.
It should use DHCP first.

Expected client results:
  - IPv4 lease: 192.168.105.100-192.168.105.199
  - Default route/router: absent
  - DNS server: absent
  - Ping 192.168.105.1: succeeds
  - NTP query to 192.168.105.1: succeeds
  - nc -vz 192.168.105.1 22: fails
  - Ping 8.8.8.8 and 10.137.20.1: currently fail, but before k3s this does
    not prove the forward chain because ip_forward is still normally 0.

Useful Linux client commands:
  ip -4 addr
  ip route
  resolvectl dns 2>/dev/null || cat /etc/resolv.conf
  ping -c 3 192.168.105.1
  chronyc -h 192.168.105.1 tracking
  nc -vz 192.168.105.1 22
EOF

confirm "Is a test device attached and ready for blocked-host-service tests?" \
  || die "attach a test device, then re-run this validation"

confirm "Did the test device receive a 192.168.105.100-199 lease with no default route, no DNS server, and working NTP to 192.168.105.1?" \
  || die "DHCP/NTP validation did not pass"

step "Start a temporary host listener on 0.0.0.0:8000"
tmpdir="$(mktemp -d)"
cleanup() {
  if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

python3 -m http.server 8000 --bind 0.0.0.0 --directory "$tmpdir" >/tmp/phase1-http-server.log 2>&1 &
server_pid="$!"
sleep 1
if kill -0 "$server_pid" 2>/dev/null; then
  ok "temporary listener running on port 8000"
else
  die "temporary listener failed to start; see /tmp/phase1-http-server.log"
fi

cat <<'EOF'

From the camera-segment test device, run:
  nc -vz 192.168.105.1 8000

Expected: connection fails. Then trigger one more blocked connection to create
a kernel log entry, for example:
  nc -vz 192.168.105.1 22
EOF

confirm "Did both blocked connection tests fail from the camera segment?" \
  || die "blocked host-service validation did not pass"

step "Check for nftables drop logs"
if sudo journalctl -k --since '10 minutes ago' | grep -q 'cam-drop-input'; then
  sudo journalctl -k --since '10 minutes ago' | grep 'cam-drop-input' | tail -5
  ok "cam-drop-input logs observed"
else
  warn "no cam-drop-input logs seen in the last 10 minutes"
  warn "trigger a blocked connection from the camera segment while watching: journalctl -k -f"
  confirm "Did a cam-drop-input log appear after re-triggering a blocked connection?" \
    || die "nftables drop logging validation did not pass"
fi

step "Manual validation reminders"
cat <<'EOF'
Confirm separately:
  - Catalyst camera-to-camera isolation passes; see catalyst-camera-isolation.md.
  - NTP query to 192.168.105.1 succeeds from the test device.
  - After Phase 2/k3s, retest forwarding with a static client gateway of
    192.168.105.1 and confirm cam-drop-fwd-* logs appear.
EOF
