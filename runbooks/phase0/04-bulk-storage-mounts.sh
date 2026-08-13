#!/usr/bin/env bash
# Phase 0.4 — direct-attached bulk storage assembly and mounts.
#
# The canonical host/minis/etc/fstab is the FULL fstab from this host: its
# root/var/opt entries are LVM device paths the install reproduces, but the
# /boot/efi line carries a disk-specific UUID generated at install time. So we do
# NOT overwrite the freshly-installed fstab. We install the array identity, md check
# schedule/throttle policy, and append only the four UUID-based bulk-storage lines
# when absent.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc
require_tools mdadm update-initramfs systemctl systemd-escape findmnt readlink timeout

declare -A BULK_UUIDS=(
  [/mnt/media]=0a94d86c-76a0-44b5-bc52-930d97ab155f
  [/mnt/games]=b43f1bcc-0556-4ed5-b038-765134aba7d3
  [/mnt/frigate]=0b69665d-53ac-4380-815d-6969713940d6
  [/mnt/backups]=cc1cedb8-ef22-44b5-b1d0-5ca020d72669
)
declare -A BULK_SOURCES=(
  [/mnt/media]=/dev/mapper/hoardvg-medialv
  [/mnt/games]=/dev/mapper/hoardvg-games
  [/mnt/frigate]=/dev/mapper/hoardvg-frigate
  [/mnt/backups]=/dev/mapper/hoardvg-backuplv
)

step "Install canonical mdadm identity and monthly-check schedule"
install_file mdadm/mdadm.conf /etc/mdadm/mdadm.conf root:root 644
install_file systemd/system/mdcheck_start.timer.d/override.conf \
  /etc/systemd/system/mdcheck_start.timer.d/override.conf root:root 644
install_file systemd/system/mdcheck_continue.timer.d/override.conf \
  /etc/systemd/system/mdcheck_continue.timer.d/override.conf root:root 644
install_file systemd/system/mdcheck_start.service.d/override.conf \
  /etc/systemd/system/mdcheck_start.service.d/override.conf root:root 644
install_file systemd/system/mdcheck_continue.service.d/override.conf \
  /etc/systemd/system/mdcheck_continue.service.d/override.conf root:root 644
sudo update-initramfs -u
sudo systemctl daemon-reload
sudo systemctl enable --now mdcheck_start.timer mdcheck_continue.timer

declare -A MDCHECK_DROPINS=(
  [mdcheck_start.timer]=/etc/systemd/system/mdcheck_start.timer.d/override.conf
  [mdcheck_continue.timer]=/etc/systemd/system/mdcheck_continue.timer.d/override.conf
  [mdcheck_start.service]=/etc/systemd/system/mdcheck_start.service.d/override.conf
  [mdcheck_continue.service]=/etc/systemd/system/mdcheck_continue.service.d/override.conf
)
for unit in "${!MDCHECK_DROPINS[@]}"; do
  dropins="$(systemctl show "$unit" -p DropInPaths --value)"
  [[ " $dropins " == *" ${MDCHECK_DROPINS[$unit]} "* ]] \
    || die "$unit did not load canonical drop-in ${MDCHECK_DROPINS[$unit]}"
done
ok "md3 identity, attended check timers, and 50000 KiB/s check cap installed"

step "Ensure all direct-storage filesystems are in /etc/fstab"
for mount in /mnt/media /mnt/games /mnt/frigate /mnt/backups; do
  line="$(awk -v target="$mount" '$1 !~ /^#/ && $2 == target {print; exit}' "$HOST_ETC/fstab")"
  [ -n "$line" ] || die "canonical fstab entry for $mount is missing from $HOST_ETC/fstab"

  if grep -qxF "$line" /etc/fstab; then
    ok "canonical $mount entry already in /etc/fstab"
  elif awk -v target="$mount" '$1 !~ /^#/ && $2 == target {found=1} END {exit !found}' /etc/fstab; then
    warn "a non-canonical active entry for $mount already exists in /etc/fstab:"
    awk -v target="$mount" '$1 !~ /^#/ && $2 == target {print NR ":" $0}' /etc/fstab >&2
    die "replace it with the canonical entry from $HOST_ETC/fstab, then re-run"
  else
    printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
    ok "appended canonical $mount entry to /etc/fstab"
  fi
done

step "Start and verify all direct-storage automounts"
sudo install -d -o root -g root -m 755 /mnt/media /mnt/games /mnt/frigate /mnt/backups
sudo systemctl daemon-reload
for mount in /mnt/media /mnt/games /mnt/frigate /mnt/backups; do
  unit="$(systemd-escape --path --suffix=automount "$mount")"
  sudo systemctl start "$unit"
  assert_direct_mount_layout "$mount" "${BULK_SOURCES[$mount]}" "${BULK_UUIDS[$mount]}"
done

cat <<'EOF'

  The md3/LVM/ext4 bulk-storage stack and all four automounts are verified.
  Local read/write throughput validation is Phase 1.4.
EOF
