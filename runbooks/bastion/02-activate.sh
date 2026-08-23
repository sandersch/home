#!/bin/sh
# Attended console-only network cutover after the Catalyst port is a trunk.
# shellcheck source=runbooks/bastion/lib.sh
. "$(dirname "$0")/lib.sh"

require_root
[ "${BASTION_LOCAL_CONSOLE:-}" = yes ] || die "refusing network cutover; run only at the physical console with BASTION_LOCAL_CONSOLE=yes"
read_recorded_nic
cmp -s "$HOST_SOURCE/etc/rc.conf.local" /etc/rc.conf.local || \
  die "installed rc.conf.local differs from the staged canonical file; rerun 01-stage-config.sh"

remove_default_routes() {
  while netstat -rn -f inet | awk '$1 == "default" { found=1 } END { exit !found }'; do
    route -qn delete default >/dev/null || die "could not remove an existing default route"
  done
}

verify_ntp_listener() {
  phase=$1
  ntp_listeners=$(netstat -an -f inet | awk '
    $1 == "udp" && $4 ~ /\.123$/ && $4 !~ /^127\./ { print $4 }
  ')
  [ "$ntp_listeners" = "10.137.10.8.123" ] || \
    die "unexpected non-loopback NTP listeners $phase: ${ntp_listeners:-none}"
}

step "Force non-routing state before exposing tagged interfaces"
grep -qx 'net.inet.ip.forwarding=0' /etc/sysctl.conf || die "canonical IPv4 forwarding setting is missing"
grep -qx 'net.inet6.ip6.forwarding=0' /etc/sysctl.conf || die "canonical IPv6 forwarding setting is missing"
sysctl -q net.inet.ip.forwarding=0
sysctl -q net.inet6.ip6.forwarding=0
[ "$(sysctl -n net.inet.ip.forwarding)" -eq 0 ] || die "IPv4 forwarding did not disable"
[ "$(sysctl -n net.inet6.ip6.forwarding)" -eq 0 ] || die "IPv6 forwarding did not disable"

step "Load an interface-independent deny-all policy before network cutover"
pfctl -nf /etc/pf.cutover.conf
sshd -t -f /etc/ssh/sshd_config
pfctl -f /etc/pf.cutover.conf
if ! pfctl -s info | grep -q 'Status: Enabled'; then
  pfctl -e
fi
# Loading a ruleset does not remove states created by the installer-era policy.
# Flush them only after deny-all is active so no password-authenticated SSH or
# other pre-hardening connection can survive the interface migration.
pfctl -F states >/dev/null
remaining_pf_states=$(pfctl -ss) || die "could not inspect the PF state table after the cutover flush"
[ -z "$remaining_pf_states" ] || die "PF state table is not empty after the cutover flush"
remaining_ssh_sessions=$(netstat -an -f inet | awk '
  $1 == "tcp" && $4 == "10.137.30.8.22" && $6 == "ESTABLISHED" { print }
')
[ -z "$remaining_ssh_sessions" ] || \
  die "an installer-era SSH session remains established after the cutover flush"
# The staged sshd_config is not active until the installer-era listener is
# restarted. Stop it while deny-all is active so the final policy can never
# admit a connection governed by the old authentication policy.
if rcctl check sshd >/dev/null 2>&1; then
  rcctl stop sshd
fi
if rcctl check sshd >/dev/null 2>&1; then
  die "the installer-era SSH listener did not stop"
fi

step "Create unattached VLAN devices and parse the final policy"
for name in vlan10 vlan30; do
  if ! ifconfig "$name" >/dev/null 2>&1; then
    ifconfig "$name" create
  fi
done
pfctl -nf /etc/pf.conf

step "Retire installer-managed network state and unnumber the physical parent"
for daemon in dhcpleased resolvd rad slaacd; do
  if rcctl get "$daemon" status >/dev/null 2>&1; then
    die "$daemon is unexpectedly enabled; rerun 01-stage-config.sh"
  fi
  if rcctl check "$daemon" >/dev/null 2>&1; then
    rcctl stop "$daemon"
  fi
  if rcctl check "$daemon" >/dev/null 2>&1; then
    die "$daemon remains running"
  fi
done
install -o root -g wheel -m 644 "$HOST_SOURCE/etc/resolv.conf" /etc/resolv.conf
ifconfig "$WIRED_IF" inet -autoconf
ifconfig "$WIRED_IF" -inet
if ifconfig "$WIRED_IF" | grep -qw AUTOCONF4; then
  die "$WIRED_IF still has AUTOCONF4 enabled"
fi
if ifconfig "$WIRED_IF" | grep -Eq '^[[:space:]]+inet '; then
  die "$WIRED_IF still has an IPv4 address"
fi
remove_default_routes

step "Activate parent and tagged interfaces"
/bin/sh /etc/netstart "$WIRED_IF" vlan30 vlan10
ifconfig "$WIRED_IF" -inet6
ifconfig vlan30 -inet6
ifconfig vlan10 -inet6
remove_default_routes
route -qn add default 10.137.30.1
for daemon in sshd ntpd; do
  rcctl get "$daemon" status >/dev/null 2>&1 || \
    die "$daemon is unexpectedly disabled; rerun 01-stage-config.sh"
done
rcctl start sshd
rcctl restart ntpd

# Verify the hardened daemons are bound only to their final addresses before
# making either listener reachable. A failure above or here leaves deny-all active.
ssh_listeners=$(netstat -an -f inet | awk '
  $1 == "tcp" && $6 == "LISTEN" && $4 !~ /^127\./ { print $4 }
')
[ "$ssh_listeners" = "10.137.30.8.22" ] || \
  die "unexpected non-loopback TCP listeners before opening PF: ${ssh_listeners:-none}"
verify_ntp_listener "before opening PF"

# Replace deny-all only after both VLAN devices own their final addresses and
# the hardened listeners are verified, so no installer-era authentication
# policy is ever reachable and antispoof expands against the connected networks.
pfctl -f /etc/pf.conf

# The first OpenNTPD start occurred under deny-all solely so its exact listener
# could be verified before opening PF. Restart it now that the final policy
# permits its pinned NTP peers and HTTPS constraint, discarding any blocked
# bootstrap attempts and their retry state before the health gate runs.
step "Restart OpenNTPD with final egress policy active"
rcctl restart ntpd || die "OpenNTPD failed to restart with final PF policy active"
verify_ntp_listener "after final-policy restart"

ok "tagged interfaces activated; run 03-validate.sh locally, then test from ryze and m5c"
