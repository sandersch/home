#!/bin/sh
# Render, syntax-check, and install canonical config without activating it.
# Run from the local console while Gi1/0/5 is still access VLAN 30.
# shellcheck source=runbooks/bastion/lib.sh
. "$(dirname "$0")/lib.sh"

require_root
[ -r "$GATE_FILE" ] || die "deployment gates are not recorded; run 00-preflight.sh"
read_recorded_nic
discover_wired_nic
[ "$WIRED_IF $WIRED_MAC" = "$(sed -n '1p' "$STATE_FILE")" ] || die "wired NIC changed since preflight"

tmpdir=$(mktemp -d /tmp/bastion-stage.XXXXXXXXXX)
created_vlans=
cleanup() {
  for name in $created_vlans; do
    ifconfig "$name" destroy 2>/dev/null || true
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT TERM

step "Render interface-specific configuration"
mkdir -p "$tmpdir/etc/ssh" "$tmpdir/home/charlie/.ssh"
for name in myname mygate resolv.conf ntpd.conf sysctl.conf rc.conf.local doas.conf pf.conf pf.cutover.conf; do
  sed "s/__WIRED_IF__/$WIRED_IF/g" "$HOST_SOURCE/etc/$name" > "$tmpdir/etc/$name"
done
sed "s/__WIRED_IF__/$WIRED_IF/g" "$HOST_SOURCE/etc/hostname.__WIRED_IF__" > "$tmpdir/etc/hostname.$WIRED_IF"
for name in vlan10 vlan30; do
  sed "s/__WIRED_IF__/$WIRED_IF/g" "$HOST_SOURCE/etc/hostname.$name" > "$tmpdir/etc/hostname.$name"
done
cp "$HOST_SOURCE/etc/ssh/sshd_config" "$tmpdir/etc/ssh/sshd_config"
cp "$HOST_SOURCE/home/charlie/.ssh/authorized_keys" "$tmpdir/home/charlie/.ssh/authorized_keys"

step "Parse daemon policy and inspect rendered interface declarations"
# PF validates interface names. Create unattached, unnumbered VLAN devices only
# for parsing, and remove only the devices this script created on exit.
for name in vlan10 vlan30; do
  if ! ifconfig "$name" >/dev/null 2>&1; then
    ifconfig "$name" create
    created_vlans="${created_vlans}${created_vlans:+ }$name"
  fi
done
pfctl -nf "$tmpdir/etc/pf.conf"
pfctl -nf "$tmpdir/etc/pf.cutover.conf"
ntpd -n -f "$tmpdir/etc/ntpd.conf"
sshd -t -f "$tmpdir/etc/ssh/sshd_config"
ssh-keygen -lf "$tmpdir/home/charlie/.ssh/authorized_keys" >/dev/null
for name in "$WIRED_IF" vlan10 vlan30; do
  file="$tmpdir/etc/hostname.$name"
  [ -s "$file" ] || die "rendered $file is empty"
  grep -q '__WIRED_IF__' "$file" && die "unrendered interface token in $file"
  description=$(sed -n 's/^description "\(.*\)"$/\1/p' "$file")
  [ -n "$description" ] || die "$file has no quoted interface description"
  [ "${#description}" -le 63 ] || die "$file interface description exceeds OpenBSD's 63-character limit"
done
grep -qx "parent $WIRED_IF" "$tmpdir/etc/hostname.vlan10" || die "vlan10 parent mismatch"
grep -qx "parent $WIRED_IF" "$tmpdir/etc/hostname.vlan30" || die "vlan30 parent mismatch"
ok "all staged configuration parses"

step "Install configuration without activation"
install -o root -g wheel -m 644 "$tmpdir/etc/myname" /etc/myname
install -o root -g wheel -m 640 "$tmpdir/etc/mygate" /etc/mygate
install -o root -g wheel -m 644 "$tmpdir/etc/resolv.conf" /etc/resolv.conf
install -o root -g wheel -m 644 "$tmpdir/etc/ntpd.conf" /etc/ntpd.conf
install -o root -g wheel -m 640 "$tmpdir/etc/sysctl.conf" /etc/sysctl.conf
install -o root -g wheel -m 640 "$tmpdir/etc/rc.conf.local" /etc/rc.conf.local
install -o root -g wheel -m 600 "$tmpdir/etc/doas.conf" /etc/doas.conf
install -o root -g wheel -m 600 "$tmpdir/etc/pf.conf" /etc/pf.conf
install -o root -g wheel -m 600 "$tmpdir/etc/pf.cutover.conf" /etc/pf.cutover.conf
install -o root -g wheel -m 600 "$tmpdir/etc/ssh/sshd_config" /etc/ssh/sshd_config
for name in "$WIRED_IF" vlan10 vlan30; do
  install -o root -g wheel -m 640 "$tmpdir/etc/hostname.$name" "/etc/hostname.$name"
done
home_dir=$(awk -F: '$1 == "charlie" { print $6 }' /etc/passwd)
[ -n "$home_dir" ] || die "cannot locate charlie home directory"
group_name=$(id -gn charlie)
install -d -o charlie -g "$group_name" -m 700 "$home_dir/.ssh"
install -o charlie -g "$group_name" -m 600 "$tmpdir/home/charlie/.ssh/authorized_keys" "$home_dir/.ssh/authorized_keys"

pfctl -nf /etc/pf.conf
pfctl -nf /etc/pf.cutover.conf
ntpd -n -f /etc/ntpd.conf
sshd -t -f /etc/ssh/sshd_config
# netstart -n renders the ifconfig operations but does not execute them. This
# catches netstart parsing/rendering problems only; 02-activate.sh is the first
# kernel-level exercise of the parent/VLAN commands, and 03-validate.sh must
# confirm their outcome from the local console.
/bin/sh /etc/netstart -n "$WIRED_IF" vlan30 vlan10 >/dev/null
ok "configuration installed but not activated; keep the local console open and convert Gi1/0/5 to the restricted trunk before 02-activate.sh"
