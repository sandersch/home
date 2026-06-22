#!/usr/bin/env bash
# Shared helpers for the Phase 0 runbook scripts.
#
# Each step script sources this file. It resolves the repo root from its own
# location (the runbooks live in the repo, which is expected to be checked out
# on the host — `minis`), so the scripts copy config straight from the canonical
# source of truth in host/minis/etc/ rather than inlining it.
#
# Usage in a step script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

# --- paths ------------------------------------------------------------------
# REPO_ROOT = two levels up from runbooks/phase0/.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
HOST_ETC="$REPO_ROOT/host/minis/etc"

# --- logging ----------------------------------------------------------------
_c_reset=$'\033[0m'; _c_blue=$'\033[1;34m'; _c_green=$'\033[1;32m'
_c_yellow=$'\033[1;33m'; _c_red=$'\033[1;31m'

step()  { printf '\n%s==> %s%s\n'   "$_c_blue"   "$*" "$_c_reset"; }
ok()    { printf '%s  ✓ %s%s\n'     "$_c_green"  "$*" "$_c_reset"; }
warn()  { printf '%s  ! %s%s\n'     "$_c_yellow" "$*" "$_c_reset" >&2; }
die()   { printf '%s  ✗ %s%s\n'     "$_c_red"    "$*" "$_c_reset" >&2; exit 1; }

# Ask a yes/no question; returns 0 for yes. Non-interactive (no TTY) => no.
confirm() {
  local prompt="${1:-Proceed?}"
  [ -t 0 ] || { warn "no TTY; assuming 'no' for: $prompt"; return 1; }
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Install a canonical config file from host/minis/etc/ to its on-disk path.
#   install_file <relpath-under-host-etc> <dest> <owner> <mode>
# Skips the copy (but still fixes owner/mode) if the dest already matches byte-for-byte.
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
  # Ensure perms/owner even on the up-to-date path.
  sudo chown "$owner" "$dest"
  sudo chmod "$mode" "$dest"
}

# --- preflight asserts shared by several scripts ----------------------------
require_not_root() {
  [ "$(id -u)" -ne 0 ] || die "run as the non-root sudo user (charlie), not root"
}
require_sudo() {
  sudo -n true 2>/dev/null || sudo true || die "this script needs sudo"
}
require_host_etc() {
  [ -d "$HOST_ETC" ] || die "host config dir not found: $HOST_ETC (is the repo checked out here?)"
}

# The netplan config is MAC-pinned. Applying it on a host where these devices are
# missing can leave the machine without the expected management address.
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

# Phase 0.1 partitioning is manual, but everything after it assumes this exact
# shape: root/var/opt on vg0, /opt on btrfs, and enough VG free space left for
# TopoLVM scratch PVCs. Fail early if the installer layout drifted.
assert_phase0_storage_layout() {
  step "Verify Phase 0 storage layout"

  for t in findmnt readlink lvs vgs awk; do
    command -v "$t" >/dev/null || die "required storage-check tool missing: $t"
  done

  assert_mount_layout / /dev/vg0/root ext4
  assert_mount_layout /var /dev/vg0/var ext4
  assert_mount_layout /opt /dev/vg0/opt btrfs

  local opt_options vg_free_gb min_free_gb
  opt_options="$(findmnt -n -o OPTIONS --target /opt)"
  [[ ",$opt_options," == *",noatime,"* ]] || die "/opt mount options are '$opt_options'; expected noatime"
  [[ ",$opt_options," == *",compress=zstd:1,"* || ",$opt_options," == *",compress=zstd,"* ]] \
    || die "/opt mount options are '$opt_options'; expected zstd compression"
  ok "/opt has expected btrfs mount options"

  for lv in root var opt; do
    lvs --noheadings "/dev/vg0/$lv" >/dev/null 2>&1 || die "missing LV: /dev/vg0/$lv"
  done

  min_free_gb="${PHASE0_MIN_VG_FREE_GB:-500}"
  vg_free_gb="$(vgs --noheadings --units g --nosuffix -o vg_free vg0 2>/dev/null | awk '{print int($1)}')"
  [ -n "$vg_free_gb" ] || die "could not read free space for VG vg0"
  [ "$vg_free_gb" -ge "$min_free_gb" ] \
    || die "vg0 has ${vg_free_gb}G free; expected at least ${min_free_gb}G left for TopoLVM scratch"
  ok "vg0 has ${vg_free_gb}G free for TopoLVM scratch"
}
