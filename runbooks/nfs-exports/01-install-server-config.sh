#!/usr/bin/env bash
# NFS exports 01 - install the canonical server config and start nfsd.
# shellcheck source=runbooks/nfs-exports/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools exportfs systemctl ss awk
assert_nfs_mounts_ready

step "Install canonical NFS server configuration"
install_file nfs.conf.d/10-homelab.conf /etc/nfs.conf.d/10-homelab.conf root:root 644
install_file exports /etc/exports root:root 644
install_file systemd/system/nfs-server.service.d/10-wait-mounts.conf \
  /etc/systemd/system/nfs-server.service.d/10-wait-mounts.conf root:root 644

step "Confirm the units NFSv4-only does not need are masked"
# Phase 0.3 masks these the moment it installs nfs-kernel-server, so on a clean build
# this is a no-op restating the state. It stays here because this workflow must not
# assume a particular Phase 0 vintage. rpc.mountd is deliberately absent from the list:
# nfsd still uses it as the export-authentication upcall handler under v4, and masking
# it breaks exports.
mask_units "${NFS_MASKED_UNITS[@]}"

step "Reload systemd and confirm the ordering drop-in took effect"
sudo systemctl daemon-reload
dropins="$(systemctl show nfs-server.service -p DropInPaths --value)"
[[ " $dropins " == *" /etc/systemd/system/nfs-server.service.d/10-wait-mounts.conf "* ]] \
  || die "nfs-server.service did not load the canonical ordering drop-in"
ok "nfs-server orders after the bulk-storage automount units"

step "Start the NFS server and publish the exports"
sudo systemctl enable --now nfs-server
sudo exportfs -ra
service_active nfs-server
service_active nfs-mountd

step "Confirm the version lockdown and bind addresses"
assert_nfs_versions_locked
assert_nfs_bind_addresses

step "Confirm rpcbind and statd stayed down"
for unit in "${NFS_MASKED_UNITS[@]}"; do
  if systemctl is-active --quiet "$unit"; then
    die "$unit is active; NFSv4-only should not need it. If nfs-server genuinely requires rpcbind on this release, unmask rpcbind.socket, record why in docs/operations.md, and re-run."
  fi
done
ok "rpcbind, statd, and gssd are inactive"

assert_nfs_exports_file
assert_nfs_export_options

cat <<'TEXT'

The exports are live but still reachable from any source the host firewall allows.
Run ./02-firewall.sh next to install the nfs_access table before announcing the share.
TEXT
