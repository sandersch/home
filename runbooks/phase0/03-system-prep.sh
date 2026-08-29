#!/usr/bin/env bash
# Phase 0.3 — system prep + hardware checks.
#   apt upgrade · base packages · host timezone · swap-off (kubelet) · hw checks · rfkill
# Quick Sync checks are enforced because Plex later depends on /dev/dri and i915.
# Coral presence is still reported only: the udev rule can be installed before the
# USB accelerator is physically attached.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc
require_tools sysctl ss

step "apt update + upgrade"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

step "Install base packages"
# chrony supersedes systemd-timesyncd (it can SERVE NTP to the camera segment in 1.3);
# the rest are host-level deps for later phases. usbutils (lsusb) + rfkill back the
# Coral check and radio-blocking below — not guaranteed on a minimal server image.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git vim sqlite3 jq age nftables dnsmasq nut chrony mdadm lvm2 smartmontools \
  usbutils rfkill nfs-kernel-server
ok "packages installed"

# Phase 0 installs dnsmasq so the dependency is present, but Phase 1 owns the
# camera DHCP config and enables the service after /etc/dnsmasq.d/cameras.conf lands.
sudo systemctl disable --now dnsmasq
ok "dnsmasq installed but disabled until Phase 1 camera DHCP config is in place"

# Same pattern for NFS: the package is a dependency here, but runbooks/nfs-exports/
# owns /etc/exports, the NFSv4-only drop-in, and the nfs_access firewall table, and
# enables the server only once all three are in place. An nfsd started before then
# would export nothing, but it would also bind 0.0.0.0:2049 without the drop-in.
sudo systemctl disable --now nfs-server
ok "nfs-kernel-server installed but disabled until runbooks/nfs-exports/ configures it"

# Mask the RPC sidecars here rather than leaving it to runbooks/nfs-exports/01.
# Installing nfs-kernel-server pulls in rpcbind, and its postinst enables and starts
# rpcbind.socket on 0.0.0.0:111 and [::]:111, TCP and UDP. Every table in
# host/minis/etc/nftables.conf is `policy accept` by design (a drop policy would break
# k3s's own nft chains), so nothing else would close that port — and runbooks/nfs-exports/
# is a separate workflow that may run much later, or not at all on a rebuild that stops
# at Phase 5. Masking here keeps the exposure window closed for the whole gap;
# runbooks/nfs-exports/01-install-server-config.sh re-verifies the same list.
#
# rpc.mountd is deliberately absent from NFS_MASKED_UNITS: nfsd still uses it as the
# export-authentication upcall handler under v4, and masking it breaks exports.
mask_units "${NFS_MASKED_UNITS[@]}"
# Both transports: rpcbind binds TCP and UDP 111. The `sport` filter is used instead of
# an awk column because `ss -tu` prepends a Netid column that `ss -t` alone does not.
rpcbind_listeners="$(ss -H -lntu 'sport = :111' 2>/dev/null || true)"
[ -z "$rpcbind_listeners" ] \
  || die "something still listens on port 111 after masking rpcbind: $rpcbind_listeners"
ok "rpcbind and the statd/gssd sidecars are masked; nothing listens on port 111"

step "Set host timezone (America/Chicago)"
# Frigate event timestamps + cross-log correlation depend on a non-UTC host tz.
sudo timedatectl set-timezone America/Chicago
ok "timezone: $(timedatectl show -p Timezone --value)"

step "Install and apply inotify limits"
install_file sysctl.d/99-inotify.conf /etc/sysctl.d/99-inotify.conf root:root 644
sudo sysctl --system >/dev/null
[ "$(sysctl -n fs.inotify.max_user_watches)" = "524288" ] \
  || die "fs.inotify.max_user_watches did not apply"
[ "$(sysctl -n fs.inotify.max_user_instances)" = "8192" ] \
  || die "fs.inotify.max_user_instances did not apply"
ok "inotify limits: 524288 watches, 8192 instances per user"

step "Confirm swap is OFF (kubelet refuses swap)"
if [ -n "$(swapon --show)" ]; then
  warn "swap is active:"; swapon --show
  if confirm "Disable all active swap now?"; then
    sudo swapoff -a
    if [ -f /swap.img ]; then
      sudo rm -f /swap.img
      sudo sed -i.bak '/\/swap\.img/d' /etc/fstab
      ok "swap disabled, /swap.img removed, fstab line stripped (backup: /etc/fstab.bak)"
    else
      ok "active swap disabled"
    fi
  else
    die "swap left active; disable it before continuing to k3s"
  fi
else
  ok "no active swap"
fi
if [ -n "$(swapon --show)" ]; then
  swapon --show
  die "swap is still active after cleanup"
fi
if awk '$1 !~ /^#/ && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
  warn "persistent swap entries remain in /etc/fstab:"
  awk '$1 !~ /^#/ && $3 == "swap" { print "    " $0 }' /etc/fstab >&2
  die "remove or comment persistent swap entries before continuing"
fi

step "Hardware checks"
echo "--- /dev/dri (Quick Sync; expect cardN + renderD128):"
ls -la /dev/dri/ 2>/dev/null || die "/dev/dri missing — enable the iGPU in BIOS, reboot, and re-run"
compgen -G '/dev/dri/card*' >/dev/null || die "/dev/dri/card* missing — Quick Sync device node is incomplete"
compgen -G '/dev/dri/renderD*' >/dev/null || die "/dev/dri/renderD* missing — Plex needs the render node for Quick Sync"
echo "--- i915 driver:"
if lsmod | grep -q '^i915'; then
  ok "i915 loaded"
else
  if ! grep -qxF i915 /etc/modules; then
    printf '%s\n' i915 | sudo tee -a /etc/modules >/dev/null
    warn "added i915 to /etc/modules"
  fi
  die "i915 is not loaded — reboot so the module loads, then re-run"
fi
echo "--- render group GID (needed by the Plex pod):"
getent group render || die "no 'render' group; Quick Sync permissions are not ready"
echo "--- Coral USB (may not be plugged in yet):"
lsusb 2>/dev/null | grep -iE '1a6e|18d1|google|coral' || warn "Coral not seen on USB yet (fine if not attached)"

step "Block unused radios (WiFi + Bluetooth) — persists across reboots"
sudo rfkill block wifi || warn "rfkill wifi failed (no wifi device?)"
sudo rfkill block bluetooth || warn "rfkill bluetooth failed (no bt device?)"
rfkill list || true

cat <<'EOF'

  IOMMU is NOT required for this build (iGPU + Coral are hostPath device access,
  not PCI passthrough). Only add intel_iommu=on to GRUB if you later want true
  passthrough — see build-plan.md 0.3 / 0.0.
EOF
