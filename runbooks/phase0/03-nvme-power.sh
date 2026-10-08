#!/usr/bin/env bash
# Phase 0.3 helper; safe to run alone on an existing minis (no upgrade or reboot).
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc
require_tools update-grub grub-script-check awk
[ "$(hostname -s)" = minis ] || die "this NVMe workaround is specific to minis"
[ -f /etc/default/grub ] || die "expected Ubuntu GRUB configuration is missing"

step "Preserve current GRUB configuration"
backup="$(sudo mktemp -d /var/backups/homelab-grub.XXXXXXXX)"
sudo cp -a /etc/default/grub "$backup/grub"
if [ -d /etc/default/grub.d ]; then
  sudo cp -a /etc/default/grub.d "$backup/grub.d"
fi
sudo cp -a /boot/grub/grub.cfg "$backup/grub.cfg"
ok "backup: $backup"

step "Persist the validated NVMe APST workaround"
install_file default/grub.d/99-homelab-nvme.cfg /etc/default/grub.d/99-homelab-nvme.cfg root:root 644
sudo update-grub || die "update-grub failed; inspect configuration before reboot (backup: $backup)"
sudo grub-script-check /boot/grub/grub.cfg \
  || die "GRUB syntax check failed; restore $backup/grub.cfg before reboot"

# Check every generated Linux entry, including older kernels and recovery mode.
# Reject conflicting values as well as a missing parameter.
sudo awk '
  $1 ~ /^linux(efi|16)?$/ {
    entries++; found=0
    for (i=2; i<=NF; i++) {
      if ($i == "nvme_core.default_ps_max_latency_us=0") found=1
      else if ($i ~ /^nvme_core.default_ps_max_latency_us=/) bad=1
    }
    if (!found) bad=1
  }
  END { exit (entries == 0 || bad) }
' /boot/grub/grub.cfg \
  || die "NVMe parameter missing or conflicting in GRUB entries; resolve before reboot (backup: $backup)"
ok "all generated Linux boot entries disable NVMe APST"

step "Check the running kernel (unchanged by update-grub)"
if grep -qwF 'nvme_core.default_ps_max_latency_us=0' /proc/cmdline \
    && [ "$(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us)" = 0 ]; then
  ok "validated setting is already active; no reboot needed to change current behavior"
else
  warn "persistent setting is ready; reboot during an attended window, then verify /proc/cmdline and the nvme_core sysfs value (must be 0)"
fi
