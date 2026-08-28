#!/bin/sh
# Read-only hardware checks, followed by a small local state record when every
# attended external deployment gate has explicitly been confirmed.
# shellcheck source=runbooks/bastion/lib.sh
. "$(dirname "$0")/lib.sh"

require_root
[ ! -e "$REPO_ROOT/age.key" ] && [ ! -L "$REPO_ROOT/age.key" ] || \
  die "refusing a deployment tree that contains age.key; transfer only runbooks/bastion and host/bastion"
step "Verify OpenBSD release and base-only host"
[ "$(uname -s)" = OpenBSD ] || die "this runbook runs only on OpenBSD"
[ "$(uname -r)" = 7.9 ] || die "expected OpenBSD 7.9; found $(uname -r)"
command -v pfctl >/dev/null || die "pfctl is missing"
command -v sshd >/dev/null || die "sshd is missing"
command -v syspatch >/dev/null || die "syspatch is missing"
[ -x /usr/X11R6/bin/X ] && die "X sets appear to be installed; rebuild with base/manual sets only"
# OpenBSD 7.9's base set includes cc, ld, and make.  A standard C header is a
# comp79.tgz-only marker; testing command -v cc incorrectly rejects a base-only
# installation.
[ -e /usr/include/stdio.h ] && die "compiler set appears to be installed; rebuild with base/manual sets only"
if command -v pkg_info >/dev/null; then
  non_firmware_packages=$(pkg_info -q 2>/dev/null | grep -Ev '(^|-)firmware-[0-9]' || true)
  [ -z "$non_firmware_packages" ] || die "non-firmware packages are installed: $non_firmware_packages"
fi
ok "OpenBSD 7.9 base system detected"

step "Verify release errata are current"
if pending_patches=$(syspatch -c); then
  [ -z "$pending_patches" ] || die "pending syspatches remain: $pending_patches"
else
  die "syspatch could not check the signed errata feed"
fi
ok "no pending syspatches"

step "Discover the sole wired interface"
discover_wired_nic
if [ -n "${BASTION_EXPECTED_MAC:-}" ] && [ "$WIRED_MAC" != "$BASTION_EXPECTED_MAC" ]; then
  die "$WIRED_IF has MAC $WIRED_MAC, expected $BASTION_EXPECTED_MAC"
fi
ok "wired interface is $WIRED_IF ($WIRED_MAC)"

step "Verify local account and approved keys"
id charlie >/dev/null 2>&1 || die "administrator account charlie does not exist"
key_file="$HOST_SOURCE/home/charlie/.ssh/authorized_keys"
[ -s "$key_file" ] || die "canonical authorized_keys is empty"
ssh-keygen -lf "$key_file" >/dev/null || die "canonical authorized_keys is invalid"
ok "charlie and at least one valid approved public key are present"

[ "${BASTION_DEPLOYMENT_GATES_CONFIRMED:-}" = yes ] || die "first verify both .9 addresses, Gi1/0/5, install-media signatures, hardware support, local console, and key possession; then rerun with BASTION_DEPLOYMENT_GATES_CONFIRMED=yes"

umask 077
printf '%s %s\n' "$WIRED_IF" "$WIRED_MAC" > "$STATE_FILE"
printf 'confirmed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$GATE_FILE"
ok "deployment gates recorded; copy $WIRED_IF / $WIRED_MAC into docs/network.md after deployment"
