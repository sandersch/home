#!/usr/bin/env bash
# Phase 0.3 — system prep + hardware checks.
#   apt upgrade · base packages · host timezone · swap-off (kubelet) · hw checks · rfkill
# Quick Sync checks are enforced because Plex later depends on /dev/dri and i915.
# Coral presence is still reported only: the udev rule can be installed before the
# USB accelerator is physically attached.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo

step "apt update + upgrade"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

step "Install base packages"
# chrony supersedes systemd-timesyncd (it can SERVE NTP to the camera segment in 1.3);
# the rest are host-level deps for later phases. usbutils (lsusb) + rfkill back the
# Coral check and radio-blocking below — not guaranteed on a minimal server image.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git vim sqlite3 jq age nftables dnsmasq nut chrony mdadm lvm2 smartmontools \
  usbutils rfkill
ok "packages installed"

# Phase 0 installs dnsmasq so the dependency is present, but Phase 1 owns the
# camera DHCP config and enables the service after /etc/dnsmasq.d/cameras.conf lands.
sudo systemctl disable --now dnsmasq
ok "dnsmasq installed but disabled until Phase 1 camera DHCP config is in place"

step "Set host timezone (America/Chicago)"
# Frigate event timestamps + cross-log correlation depend on a non-UTC host tz.
sudo timedatectl set-timezone America/Chicago
ok "timezone: $(timedatectl show -p Timezone --value)"

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
