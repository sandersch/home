#!/usr/bin/env bash
# NFS exports 02 - install the nfs_access nftables table.
#
# RELOAD, NEVER RESTART. Stock Ubuntu's nftables.service ships
# `ExecStop=/usr/sbin/nft flush ruleset`, so a restart would flush every table --
# including the nat/filter/mangle chains k3s/flannel/kube-proxy own.
# shellcheck source=runbooks/nfs-exports/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools nft systemctl

step "Validate the canonical nftables config before installing"
sudo nft -c -f "$HOST_ETC/nftables.conf" \
  || die "nftables syntax check failed for $HOST_ETC/nftables.conf"
ok "nftables syntax check passed"

step "Install and reload nftables"
install_file nftables.conf /etc/nftables.conf root:root 644
sudo systemctl reload nftables
service_active nftables

step "Confirm all four host tables are loaded"
for table in camera_isolation frigate_access ups_access nfs_access; do
  sudo nft list table inet "$table" >/dev/null \
    || die "$table nftables table is not loaded after reload"
  ok "$table is active"
done

step "Confirm k3s chains survived the reload"
# The canonical file has no `flush ruleset`, so kube-proxy/flannel state must be intact.
sudo nft list tables | grep -qE '(^|\s)(ip|inet) (kube-proxy|nat|filter)' \
  || warn "no kube-proxy/nat/filter tables listed; verify pod networking before leaving this step"
if kubectl get nodes >/dev/null 2>&1; then
  ok "the k3s API is still reachable after the reload"
else
  warn "could not reach the k3s API from here; verify pod networking manually"
fi

assert_nfs_firewall

cat <<'TEXT'

The listener is scoped to destination addresses 10.137.20.5/127.0.0.1. nfs_access now
enforces the source/interface packet policy, and /etc/exports separately authorizes
VLAN 20/30 clients for mounts. Run ./03-validate.sh next.
TEXT
