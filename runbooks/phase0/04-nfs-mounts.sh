#!/usr/bin/env bash
# Phase 0.4 — NFS media mount.
#
# The canonical host/minis/etc/fstab is the FULL fstab from this host: its
# root/var/opt entries are LVM device paths the install reproduces, but the
# /boot/efi line carries a disk-specific UUID generated at install time. So we do
# NOT overwrite the freshly-installed fstab — we only APPEND the NAS NFS line if it
# isn't already present (the safe path build-plan.md 0.4 calls out for an existing
# install). nofail/_netdev are essential: a NAS outage at boot must not block k3s.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc

NFS_LINE="$(grep -E '^[^#]*media\.nfs\.service\.matrix' "$HOST_ETC/fstab")" \
  || die "could not find the NFS line in $HOST_ETC/fstab"
NAS_HOST="media.nfs.service.matrix"

step "Confirm the NAS hostname resolves (no /etc/hosts fallback)"
if getent hosts "$NAS_HOST" >/dev/null; then
  ok "$NAS_HOST -> $(getent hosts "$NAS_HOST" | awk '{print $1}')"
else
  die "$NAS_HOST does not resolve — the boot mount depends on the router DNS (10.137.20.1). Fix DNS first."
fi

step "Ensure the NFS mount is in /etc/fstab"
if grep -qxF "$NFS_LINE" /etc/fstab; then
  ok "canonical NFS line already in /etc/fstab"
elif grep -Eq "^[[:space:]]*$NAS_HOST:/mnt/media[[:space:]]+/mnt/media[[:space:]]+" /etc/fstab; then
  warn "a non-canonical active NFS line for $NAS_HOST:/mnt/media already exists in /etc/fstab:"
  grep -En "^[[:space:]]*$NAS_HOST:/mnt/media[[:space:]]+/mnt/media[[:space:]]+" /etc/fstab >&2
  die "replace that line with the canonical entry from $HOST_ETC/fstab, then re-run"
else
  printf '%s\n' "$NFS_LINE" | sudo tee -a /etc/fstab >/dev/null
  ok "appended canonical NFS line to /etc/fstab"
fi

step "Mount and verify /mnt/media"
# The mountpoint doesn't exist on a fresh install; create it before mounting
# (x-systemd.automount would create it lazily, but a direct mount would not).
sudo install -d -o root -g root -m 755 /mnt/media
mount_out="$(mktemp)"
mount_err="$(mktemp)"
ls_out="$(mktemp)"
ls_err="$(mktemp)"
trap 'rm -f "$mount_out" "$mount_err" "$ls_out" "$ls_err"' EXIT

# Mount only the Phase 0 NFS target and bound the attempt. A bad NAS/export should
# fail the runbook clearly, not leave the SSH session stuck in `mount -a`.
if timeout 30 sudo mount /mnt/media >"$mount_out" 2>"$mount_err"; then
  ok "mount /mnt/media completed"
else
  warn "could not mount /mnt/media within 30s:"
  sed -n '1,20p' "$mount_err" >&2 || true
  die "/mnt/media did not mount; fix NAS DNS/export/reachability before continuing"
fi

# The fstab entry uses x-systemd.automount, so the first read can still be what
# proves the remote filesystem is reachable. Treat failure or a hang as real.
if timeout 20 ls -la /mnt/media >"$ls_out" 2>"$ls_err"; then
  ok "/mnt/media is readable"
  sed -n '1,20p' "$ls_out"
else
  warn "could not read /mnt/media:"
  sed -n '1,20p' "$ls_err" >&2 || true
  die "/mnt/media is not usable; fix NAS DNS/export/reachability before continuing"
fi
rm -f "$mount_out" "$mount_err" "$ls_out" "$ls_err"
trap - EXIT

cat <<'EOF'

  Only /mnt/media is mounted at this stage. /mnt/frigate and /mnt/games are added
  in Phase 4 with the apps that need them.
  Throughput validation (iperf3 / fio over /mnt/media) is Phase 1.4.
EOF
