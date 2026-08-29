#!/usr/bin/env bash
# NFS exports 00 - read-only preflight. Changes nothing.
# shellcheck source=runbooks/nfs-exports/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools nft ss systemctl findmnt readlink timeout awk
assert_phase0_network_settled
assert_nfs_mounts_ready

step "Verify the NFS server package is installed"
command -v exportfs >/dev/null \
  || die "nfs-kernel-server is not installed; run Phase 0.3 system prep or 'sudo apt install nfs-kernel-server'"
ok "nfs-kernel-server is present"

step "Verify nothing is exported yet"
existing="$(sudo exportfs -s 2>/dev/null || true)"
if [ -n "$existing" ]; then
  printf '%s\n' "$existing" >&2
  die "this host already exports filesystems; reconcile with host/minis/etc/exports before continuing"
fi
if [ -s /etc/exports ] && ! sudo cmp -s "$HOST_ETC/exports" /etc/exports; then
  warn "/etc/exports is non-empty and differs from the canonical file; 01 will overwrite it"
  confirm "Overwrite /etc/exports with the canonical file?" \
    || die "reconcile /etc/exports by hand, then re-run"
fi
ok "no pre-existing exports to reconcile"

step "Verify mount-root ownership matches the squash policy"
# /mnt/media relies on per-uid identity (root_squash) and /mnt/games squashes everyone
# to 1000:1000, so both mount roots must actually be owned by uid 1000.
for mount in /mnt/media /mnt/games; do
  owner="$(stat -c '%u' "$mount")"
  [ "$owner" = "1000" ] \
    || die "$mount is owned by uid $owner, not 1000; the squash policy assumes uid 1000 owns both trees"
done
ok "/mnt/media and /mnt/games are owned by uid 1000"

step "Verify the client-facing DNS names resolve to this host"
# Clients mount by name (docs/operations.md -> Client mount options), but every gate in
# this workflow mounts by IP, so nothing else would catch a missing or stale record.
# A warning, not a failure: the exports themselves work by address, and the UDM record
# is the one piece of this design that does not live in the repo.
for name in media.nfs.service.matrix games.nfs.service.matrix; do
  resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -z "$resolved" ]; then
    warn "$name does not resolve; add the *.nfs.service.matrix record on the UDM (docs/network.md)"
  elif [ "$resolved" != "10.137.20.5" ]; then
    warn "$name resolves to $resolved, not 10.137.20.5; the UDM record is stale"
  else
    ok "$name -> $resolved"
  fi
done

step "Verify nftables is running and its existing tables are intact"
service_active nftables
for table in camera_isolation frigate_access ups_access; do
  sudo nft list table inet "$table" >/dev/null \
    || die "$table nftables table is missing; do not layer nfs_access onto a broken ruleset"
done
ok "camera_isolation, frigate_access, and ups_access are loaded"

cat <<'TEXT'

Preflight passed. Next:
  ./01-install-server-config.sh   install nfs.conf drop-in, exports, unit drop-in, mask v3 units
  ./02-firewall.sh                install the nfs_access nftables table
  ./03-validate.sh                server-side and client-side gates
  ./04-validate-monitoring.sh     Prometheus probe, alert, and collector gates
TEXT
