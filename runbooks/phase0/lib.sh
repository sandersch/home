#!/usr/bin/env bash
# Phase 0 helpers.
#
# Scripts source this file; it loads common runbook helpers, then keeps the
# Phase 0-only storage layout assertion here.
# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# shellcheck disable=SC2034 # Used by run-all.sh after sourcing this phase lib.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
