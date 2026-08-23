#!/bin/sh
# Read-only host validation. Client, switch, UDM, reboot, and AC-loss checks are
# deliberately retained as attended checklist items in README.md.
# shellcheck source=runbooks/bastion/lib.sh
. "$(dirname "$0")/lib.sh"

require_root
read_recorded_nic
fail=0
check() {
  description=$1
  shift
  if "$@"; then ok "$description"; else printf 'FAIL: %s\n' "$description" >&2; fail=1; fi
}

parent_has_no_ip() { ! ifconfig "$WIRED_IF" | grep -Eq '^[[:space:]]+inet6? '; }
parent_has_no_autoconf() { ! ifconfig "$WIRED_IF" | grep -qw AUTOCONF4; }
only_expected_vlans() {
  actual=$(ifconfig -a | sed -n 's/^\(vlan[0-9][0-9]*\):.*/\1/p' | sort | tr '\n' ' ')
  [ "$actual" = "vlan10 vlan30 " ]
}
no_ipv6() {
  for iface in "$WIRED_IF" vlan10 vlan30; do
    ifconfig "$iface" | grep -q 'inet6 ' && return 1
  done
  return 0
}
one_default() {
  netstat -rn -f inet | awk '
    $1 == "default" { total++ }
    $1 == "default" && $2 == "10.137.30.1" { expected++ }
    END { exit !(total == 1 && expected == 1) }
  '
}
forwarding_off() { [ "$(sysctl -n net.inet.ip.forwarding)" -eq 0 ] && [ "$(sysctl -n net.inet6.ip6.forwarding)" -eq 0 ]; }
daemon_is_disabled_and_stopped() {
  daemon=$1
  ! rcctl get "$daemon" status >/dev/null 2>&1 &&
    ! rcctl check "$daemon" >/dev/null 2>&1
}
resolver_is_canonical() {
  actual=$(awk 'NF && $1 !~ /^#/ { print }' /etc/resolv.conf)
  expected=$(printf '%s\n' 'nameserver 10.137.30.1' 'lookup file bind')
  [ "$actual" = "$expected" ]
}
vlan_has_parent_and_tag() {
  iface=$1
  expected_tag=$2
  ifconfig "$iface" | awk -v parent="$WIRED_IF" -v tag="$expected_tag" '
    $1 == "encap:" && $2 == "vnetid" && $3 == tag &&
      $4 == "parent" && $5 == parent { found=1 }
    END { exit !found }
  '
}
only_external_tcp_listener() {
  listeners=$(netstat -an -f inet | awk '$1 == "tcp" && $6 == "LISTEN" && $4 !~ /^127\./ { print $4 }')
  [ "$listeners" = "10.137.30.8.22" ]
}
no_nat_or_rdr() { [ -z "$(pfctl -sn 2>/dev/null)" ]; }
pf_states_are_interface_bound() {
  grep -qx 'set state-policy if-bound' /etc/pf.conf || return 1
  rules=$(pfctl -sr) || return 1
  pass_rules=$(printf '%s\n' "$rules" | awk '$1 == "pass" { print }')
  [ -n "$pass_rules" ] || return 1
  ! printf '%s\n' "$pass_rules" | grep -Ev ' keep state \([^)]*if-bound([^)]*)?\)'
}
vlan10_deny_limiter_is_loaded() {
  rules=$(pfctl -sr) || return 1
  logged=$(printf '%s\n' "$rules" | grep 'label "vlan10-denied-logged"') || return 1
  unlogged=$(printf '%s\n' "$rules" | grep 'label "vlan10-denied-unlogged"') || return 1
  [ "$(printf '%s\n' "$logged" | wc -l | tr -d ' ')" -eq 1 ] &&
    [ "$(printf '%s\n' "$unlogged" | wc -l | tr -d ' ')" -eq 1 ] &&
    printf '%s\n' "$logged" | grep -Eq 'block.* in log quick on vlan10 ' &&
    printf '%s\n' "$logged" | grep -q 'max-pkt-rate 5/1' &&
    printf '%s\n' "$unlogged" | grep -Eq 'block.* in quick on vlan10 ' &&
    ! printf '%s\n' "$unlogged" | grep -q 'max-pkt-rate'
}
no_forwarding_or_autoconf_components() {
  ! ifconfig -a | grep -Eq '^(bridge|veb|vport|vether|trunk|carp|gif|gre|wg)[0-9]+:' &&
    ! pgrep -q '^(bgpd|ospfd|ospf6d|ripd|dvmrpd|relayd|rad|slaacd)$'
}

step "Validate host invariants"
check "physical parent has no IP address" parent_has_no_ip
check "physical parent has AUTOCONF4 disabled" parent_has_no_autoconf
check "dhcpleased is disabled and stopped" daemon_is_disabled_and_stopped dhcpleased
check "resolvd is disabled and stopped" daemon_is_disabled_and_stopped resolvd
check "rad is disabled and stopped" daemon_is_disabled_and_stopped rad
check "slaacd is disabled and stopped" daemon_is_disabled_and_stopped slaacd
check "/etc/resolv.conf contains only the canonical VLAN 30 resolver policy" resolver_is_canonical
check "only vlan10 and vlan30 VLAN interfaces exist" only_expected_vlans
check "vlan10 uses the recorded physical parent and vnetid 10" vlan_has_parent_and_tag vlan10 10
check "vlan30 uses the recorded physical parent and vnetid 30" vlan_has_parent_and_tag vlan30 30
check "parent and both VLANs have no IPv6 address" no_ipv6
check "vlan30 owns 10.137.30.8" sh -c "ifconfig vlan30 | grep -q 'inet 10.137.30.8 '"
check "vlan10 owns 10.137.10.8" sh -c "ifconfig vlan10 | grep -q 'inet 10.137.10.8 '"
check "sole default route is via 10.137.30.1" one_default
check "IPv4 and IPv6 forwarding are disabled" forwarding_off
check "the only non-loopback TCP listener is 10.137.30.8:22" only_external_tcp_listener
check "PF is enabled" sh -c 'pfctl -s info | grep -q "Status: Enabled"'
check "PF has no NAT or redirection rules" no_nat_or_rdr
check "all active PF pass states are interface-bound" pf_states_are_interface_bound
check "active PF ruleset contains the VLAN 10 deny limiter and fallback" vlan10_deny_limiter_is_loaded
check "no bridge, routing/relay, RA, or SLAAC component is active" no_forwarding_or_autoconf_components
check "installed PF config parses" pfctl -nf /etc/pf.conf
check "installed ntpd config parses" ntpd -n -f /etc/ntpd.conf
check "installed sshd config parses" sshd -t -f /etc/ssh/sshd_config

if [ "$fail" -ne 0 ]; then
  die "host validation failed; leave Rule 940 disabled and recover from the local console"
fi
ok "local host validation passed"
