#!/usr/bin/env bash
# Common helpers for host-side runbook scripts.
#
# Phase-specific lib.sh files source this file, then add only the checks or path
# aliases unique to that phase.

set -euo pipefail

RUNBOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RUNBOOKS_DIR/.." && pwd)"
HOST_ETC="$REPO_ROOT/host/minis/etc"

_c_reset=$'\033[0m'; _c_blue=$'\033[1;34m'; _c_green=$'\033[1;32m'
_c_yellow=$'\033[1;33m'; _c_red=$'\033[1;31m'

step()  { printf '\n%s==> %s%s\n' "$_c_blue" "$*" "$_c_reset"; }
ok()    { printf '%s  [OK] %s%s\n' "$_c_green" "$*" "$_c_reset"; }
warn()  { printf '%s  [!] %s%s\n' "$_c_yellow" "$*" "$_c_reset" >&2; }
die()   { printf '%s  [X] %s%s\n' "$_c_red" "$*" "$_c_reset" >&2; exit 1; }

confirm() {
  local prompt="${1:-Proceed?}" reply
  [ -t 0 ] || { warn "no TTY; assuming 'no' for: $prompt"; return 1; }
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

install_file() {
  local rel="$1" dest="$2" owner="$3" mode="$4"
  local src="$HOST_ETC/$rel"
  [ -f "$src" ] || die "missing source file: $src"
  if [ -f "$dest" ] && sudo cmp -s "$src" "$dest"; then
    ok "$dest already up to date"
  else
    sudo install -D -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$src" "$dest"
    ok "installed $dest ($owner $mode)"
  fi
  sudo chown "$owner" "$dest"
  sudo chmod "$mode" "$dest"
}

require_not_root() {
  [ "$(id -u)" -ne 0 ] || die "run as the non-root sudo user (charlie), not root"
}

require_sudo() {
  sudo -n true 2>/dev/null || sudo true || die "this script needs sudo"
}

require_host_etc() {
  [ -d "$HOST_ETC" ] || die "host config dir not found: $HOST_ETC (is the repo checked out here?)"
}

require_tools() {
  local missing=0 t
  for t in "$@"; do
    if ! command -v "$t" >/dev/null; then
      warn "required tool missing: $t"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "install missing tools before continuing"
}

assert_expected_nics() {
  local missing=0 name mac ifname
  for pair in "lan0:38:05:25:35:fb:d3" "cam0:38:05:25:35:fb:d2"; do
    name="${pair%%:*}"; mac="${pair#*:}"
    if ip -o link | grep -qi "$mac"; then
      ifname="$(ip -o link | grep -i "$mac" | awk -F': ' '{print $2}' | head -1)"
      ok "$name NIC ($mac) present as '$ifname'"
    else
      warn "$name NIC ($mac) not found"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "expected NIC MACs are missing; do not apply the MAC-pinned netplan config"
}

assert_mount_layout() {
  local mount="$1" expected_source="$2" expected_fstype="$3"
  local source fstype source_real expected_real

  source="$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null || true)"
  fstype="$(findmnt -n -o FSTYPE --target "$mount" 2>/dev/null || true)"
  [ -n "$source" ] || die "$mount is not mounted"
  [ "$fstype" = "$expected_fstype" ] || die "$mount is $fstype, expected $expected_fstype"

  source_real="$(readlink -f "$source" 2>/dev/null || true)"
  expected_real="$(readlink -f "$expected_source" 2>/dev/null || true)"
  [ -n "$source_real" ] && [ -n "$expected_real" ] || die "cannot resolve $mount source ($source) or expected source ($expected_source)"
  [ "$source_real" = "$expected_real" ] || die "$mount is mounted from $source, expected $expected_source"

  ok "$mount is $expected_source ($expected_fstype)"
}

assert_nfs_mount_layout() {
  local mount="$1" expected_source="$2" expected_fstype="$3"
  local source fstype

  source="$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null || true)"
  fstype="$(findmnt -n -o FSTYPE --target "$mount" 2>/dev/null || true)"
  [ -n "$source" ] || die "$mount is not mounted"
  [ "$fstype" = "$expected_fstype" ] || die "$mount is $fstype, expected $expected_fstype"
  [ "$source" = "$expected_source" ] || die "$mount is mounted from $source, expected $expected_source"

  ok "$mount is $expected_source ($expected_fstype)"
}

assert_interface_has_address() {
  local iface="$1" cidr="$2"
  ip link show "$iface" >/dev/null 2>&1 || die "interface $iface is missing; reboot after Phase 0 networking so lan0/cam0 names settle"
  ip -o -4 addr show dev "$iface" | awk '{print $4}' | grep -qxF "$cidr" \
    || die "$iface does not have expected address $cidr"
  ok "$iface has $cidr"
}

assert_phase0_network_settled() {
  step "Verify Phase 0 network state"
  assert_interface_has_address lan0 10.137.20.5/24
  assert_interface_has_address cam0 192.168.105.1/24
  assert_interface_has_address cam0 192.168.1.2/24
  ip -4 route show default | grep '^default via 10\.137\.20\.1 ' >/dev/null \
    || die "default route is not via 10.137.20.1"
  ok "default route points at 10.137.20.1"
}

service_active() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    ok "$svc is active"
  else
    sudo systemctl --no-pager --full status "$svc" || true
    die "$svc is not active"
  fi
}
