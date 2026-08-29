#!/usr/bin/env bash
# NFS export runbook helpers.
#
# Loads the common runbook helpers, then keeps the export-specific constants and
# assertions here. See docs/operations.md → NFS exports.
# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# The two exported filesystems, and only these two. /mnt/frigate stays local to the
# colocated Frigate workload and /mnt/backups stays unexported.
# shellcheck disable=SC2034
declare -A NFS_EXPORT_SOURCES=(
  [/mnt/media]=/dev/mapper/hoardvg-medialv
  [/mnt/games]=/dev/mapper/hoardvg-games
)
# shellcheck disable=SC2034
declare -A NFS_EXPORT_UUIDS=(
  [/mnt/media]=0a94d86c-76a0-44b5-bc52-930d97ab155f
  [/mnt/games]=b43f1bcc-0556-4ed5-b038-765134aba7d3
)

# NFS_MASKED_UNITS and mask_units() live in runbooks/lib.sh: Phase 0.3 installs
# nfs-kernel-server and masks the same units immediately, so this workflow is
# re-verifying that list rather than owning it.

# Addresses nfsd is allowed to bind. lan0 plus loopback only -- never 0.0.0.0, and never
# cam0's 192.168.105.1 or its 192.168.1.2 alias.
# shellcheck disable=SC2034
NFS_BIND_ADDRESSES=(10.137.20.5 127.0.0.1)

assert_nfs_mounts_ready() {
  step "Verify both exported filesystems are mounted from their canonical devices"
  local mount
  for mount in /mnt/media /mnt/games; do
    assert_direct_mount_layout "$mount" \
      "${NFS_EXPORT_SOURCES[$mount]}" "${NFS_EXPORT_UUIDS[$mount]}"
  done
}

# Exact whitespace-token match against a /proc/fs/nfsd/versions token list.
# `grep -w` is wrong here: `.` is not a word character, so `grep -w -- '+4'` also
# matches inside the `+4.1` token and every "is v4 enabled" check would pass
# vacuously. Substring matching has the same flaw.
_nfs_version_enabled() {
  local want="$1" tok
  shift
  for tok in "$@"; do
    [ "$tok" = "$want" ] && return 0
  done
  return 1
}

assert_nfs_versions_locked() {
  local versions
  versions="$(sudo cat /proc/fs/nfsd/versions 2>/dev/null || true)"
  [ -n "$versions" ] || die "/proc/fs/nfsd/versions is unreadable; is nfsd running?"

  local -a tokens
  read -r -a tokens <<<"$versions"

  # Gate on the `+` (enabled) forms only, in both directions. A version the kernel was
  # built without is omitted from this file entirely rather than listed as `-N`, and
  # Ubuntu 24.04's 6.8 kernel ships without CONFIG_NFSD_V2 — so requiring a literal
  # `-2` would fail a host whose lockdown is in fact correct. "Disabled" and "not
  # compiled in" are equally acceptable; only "enabled" is a finding.
  local v
  for v in +2 +3 +4.0; do
    if _nfs_version_enabled "$v" "${tokens[@]}"; then
      die "nfsd versions are '$versions'; ${v#+} must not be enabled (NFSv4.1/4.2 only)"
    fi
  done
  # `+4` is the v4 family switch and is listed alongside the minor versions.
  for v in +4 +4.1 +4.2; do
    if ! _nfs_version_enabled "$v" "${tokens[@]}"; then
      die "nfsd versions are '$versions'; expected ${v#+} to be enabled (NFSv4.1/4.2 only)"
    fi
  done
  ok "nfsd serves 4.1/4.2 only (versions: $versions)"
}

assert_nfs_bind_addresses() {
  local listeners addr
  listeners="$(ss -H -tlnp 2>/dev/null | awk '$4 ~ /:2049$/ {print $4}')"
  [ -n "$listeners" ] || die "nothing is listening on TCP 2049"
  grep -qE '^(0\.0\.0\.0|\*|\[::\]):2049$' <<<"$listeners" \
    && die "nfsd is listening on a wildcard address; expected only ${NFS_BIND_ADDRESSES[*]}"
  for addr in "${NFS_BIND_ADDRESSES[@]}"; do
    grep -qxF "$addr:2049" <<<"$listeners" \
      || die "nfsd is not listening on $addr:2049 (found: $(paste -sd ' ' - <<<"$listeners"))"
  done
  for addr in 192.168.105.1 192.168.1.2; do
    grep -qxF "$addr:2049" <<<"$listeners" \
      && die "nfsd is listening on the camera-segment address $addr; it must never be exported on cam0"
  done
  ok "nfsd listens only on ${NFS_BIND_ADDRESSES[*]} (TCP 2049)"
}

assert_nfs_exports_file() {
  # The canonical file is the source of truth for the client CIDRs, fsid values, and
  # the `mountpoint` guard. Check it directly rather than parsing `exportfs -v`, whose
  # rendered option list is a kernel-side normalization and not a faithful echo.
  sudo cmp -s "$HOST_ETC/exports" /etc/exports \
    || die "/etc/exports differs from the canonical host/minis/etc/exports"

  # Join the backslash continuations so each export is one logical line to match on.
  local joined mount uuid line
  joined="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$HOST_ETC/exports")"

  for mount in /mnt/media /mnt/games; do
    uuid="${NFS_EXPORT_UUIDS[$mount]}"
    line="$(grep "^${mount}[[:space:]]" <<<"$joined")"
    [ -n "$line" ] || die "$mount has no entry in the canonical exports file"
    grep -q '10\.137\.20\.0/24' <<<"$line" || die "$mount is not exported to VLAN 20"
    grep -q '10\.137\.30\.0/24' <<<"$line" || die "$mount is not exported to VLAN 30"
    grep -q "fsid=$uuid" <<<"$line" || die "$mount does not pin fsid=$uuid"
    grep -q 'mountpoint' <<<"$line" || die "$mount is missing the mountpoint guard"
    grep -q 'sec=sys' <<<"$line" || die "$mount does not pin sec=sys"
    grep -q '[(,]rw[,)]' <<<"$line" || die "$mount is not exported read/write"
    grep -q '[(,]sync[,)]' <<<"$line" || die "$mount is not exported sync (async is unsafe here)"
  done

  # Nothing beyond the two intended filesystems is ever exported.
  local declared
  declared="$(grep -E '^/' "$HOST_ETC/exports" | awk '{print $1}' | sort -u | paste -sd ' ' -)"
  [ "$declared" = "/mnt/games /mnt/media" ] \
    || die "/etc/exports declares '$declared'; expected exactly '/mnt/games /mnt/media'"
  ok "/etc/exports matches the canonical file and declares only /mnt/media and /mnt/games"
}

assert_nfs_export_options() {
  # Runtime view. Note exportfs renders negated flags too (`no_all_squash`,
  # `no_root_squash`, `async`), so every pattern below is anchored on a delimiter --
  # a bare grep for "sync" would also match "async" and a bare "all_squash" would
  # match "no_all_squash".
  local exports mount exported
  exports="$(sudo exportfs -v)"

  exported="$(awk '/^\// {print $1}' <<<"$exports" | sort -u | paste -sd ' ' -)"
  [ "$exported" = "/mnt/games /mnt/media" ] \
    || die "exportfs reports '$exported'; expected exactly '/mnt/games /mnt/media'"

  local media games
  media="$(grep '^/mnt/media' <<<"$exports")"
  games="$(grep '^/mnt/games' <<<"$exports")"
  [ -n "$media" ] || die "/mnt/media is not exported"
  [ -n "$games" ] || die "/mnt/games is not exported"

  # /mnt/media keeps per-uid identity so pod-written and workstation-written files
  # share ownership; /mnt/games squashes everyone to the RomM owner.
  grep -q '[(,]root_squash[,)]' <<<"$media" || die "/mnt/media is not root_squash"
  grep -q '[(,]no_all_squash[,)]' <<<"$media" \
    || die "/mnt/media is all_squash; it must preserve per-uid identity"
  grep -q '[(,]all_squash[,)]' <<<"$games" || die "/mnt/games is not all_squash"
  grep -q 'anonuid=1000' <<<"$games" || die "/mnt/games does not squash to anonuid=1000"
  grep -q 'anongid=1000' <<<"$games" || die "/mnt/games does not squash to anongid=1000"

  for mount in "$media" "$games"; do
    grep -q '[(,]rw[,)]' <<<"$mount" || die "an export is not read/write: $mount"
    grep -q '[(,]sync[,)]' <<<"$mount" || die "an export is not sync: $mount"
  done
  ok "effective export options carry the expected read/write and squash policy"
}

assert_nfs_firewall() {
  sudo nft list table inet nfs_access >/dev/null 2>&1 \
    || die "nfs_access nftables table is not loaded"
  local rules
  rules="$(sudo nft list table inet nfs_access)"
  local cidr
  for cidr in 10.137.20.0/24 10.137.30.0/24 10.42.0.0/16; do
    grep -q "$cidr" <<<"$rules" || die "nfs_access does not allow $cidr"
  done
  grep -q 'iifname "cam0"' <<<"$rules" \
    || die "nfs_access has no explicit cam0 drop"
  grep -q 'nfs-drop-input' <<<"$rules" \
    || die "nfs_access is missing the rate-limited drop log"
  ok "nfs_access allows only loopback, the pod CIDR, and VLANs 20/30"
}
