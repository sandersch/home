#!/usr/bin/env bash
# Phase 0.2 — static networking (NIC1 first), via Netplan, and stop cloud-init
# from re-rendering the installer's DHCP stub on reboot.
#
# The netplan config pins the two 2.5GbE ports to friendly names lan0/cam0 by MAC
# (match/set-name). The RENAME LANDS ON REBOOT — `netplan apply` cannot rename a
# live, addressed link, so lan0/cam0 won't appear until the next boot; the static
# addressing still applies now to the current kernel names.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc

step "Verify expected NIC MACs before installing MAC-pinned netplan"
assert_expected_nics

step "Disable cloud-init network rendering"
install_file cloud/cloud.cfg.d/99-disable-network-config.cfg \
  /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg root:root 644

step "Install Netplan config (mode 600 — netplan refuses anything looser)"
install_file netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml root:root 600

step "Check for other (stale) netplan files"
# Netplan MERGES every *.yaml/*.yml in /etc/netplan. A leftover installer/cloud-init
# file (e.g. 50-cloud-init.yaml with DHCP on NIC1) would coexist with our static
# MAC-pinned config and partially DHCP-manage the link. Disabling cloud-init's
# renderer (above) stops regeneration but does NOT remove an already-written file.
shopt -s nullglob
others=()
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
  [ "$f" = /etc/netplan/00-installer-config.yaml ] && continue
  others+=("$f")
done
shopt -u nullglob
if [ "${#others[@]}" -gt 0 ]; then
  warn "other netplan files present (netplan would merge these):"
  printf '    %s\n' "${others[@]}"
  if confirm "Move them aside to *.disabled.<ts> so only 00-installer-config.yaml is active?"; then
    ts="$(date +%s)"
    for f in "${others[@]}"; do sudo mv "$f" "$f.disabled.$ts"; ok "moved $f -> $f.disabled.$ts"; done
  else
    die "conflicting netplan files present; move them aside (sudo mv /etc/netplan/<file> /root/) and re-run"
  fi
else
  ok "no other netplan files"
fi

step "Generate + apply netplan"
sudo netplan generate
warn "netplan apply may briefly blip the link; on first apply lan0/cam0 rename only after reboot"
if confirm "Run 'netplan apply' now?"; then
  sudo netplan apply
  ok "netplan applied"
else
  if [ "${PHASE0_REQUIRE_NETPLAN_APPLY:-0}" = "1" ]; then
    die "skipped 'netplan apply'; run it manually or re-run this step when ready"
  fi
  warn "skipped 'netplan apply' — run it manually when ready: sudo netplan apply"
fi

step "Interface status"
ip -brief address show || true
cat <<'EOF'

  Expected once settled (after a reboot for the rename):
    lan0  10.137.20.5/24   (NIC1, primary LAN, default route via 10.137.20.1)
    cam0  192.168.105.1/24 + 192.168.1.2/24  (NIC2, camera segment; optional, may have
                                              no carrier until the switch/cameras arrive)
  Confirm lan0 carries 10.137.20.5 and the default route works before continuing.
EOF
