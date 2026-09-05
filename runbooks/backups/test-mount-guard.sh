#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

guard="$tmpdir/assert-backups-mount.sh"
yq -r '.data."assert-backups-mount.sh"' \
  "$repo_root/infrastructure/monitoring/restic-mount-guard.yaml" >"$guard"
chmod +x "$guard"

mount_path="$tmpdir/repo"
mountinfo="$tmpdir/mountinfo"
mkdir -p "$mount_path"
printf '%s\n' 'cc1cedb8-ef22-44b5-b1d0-5ca020d72669' >"$mount_path/.backup-sentinel"
chmod 0444 "$mount_path/.backup-sentinel"

run_guard() {
  BACKUP_MOUNT_PATH="$mount_path" \
  BACKUP_SENTINEL_UID="$(id -u)" \
  BACKUP_SENTINEL_GID="$(id -g)" \
  MOUNTINFO_PATH="$mountinfo" \
  "$guard" >/dev/null 2>&1
}

write_mountinfo() {
  printf '36 25 0:32 / %s %s - %s %s %s\n' \
    "$mount_path" "$1" "$2" "$3" "$4" >"$mountinfo"
}

write_mountinfo rw,relatime ext4 /dev/mapper/hoardvg-backuplv rw
run_guard

write_mountinfo rw,relatime autofs systemd-1 rw
! run_guard

write_mountinfo rw,relatime ext4 /dev/mapper/vg0-root rw
! run_guard

write_mountinfo ro,relatime ext4 /dev/mapper/hoardvg-backuplv ro
! run_guard

write_mountinfo rw,relatime xfs /dev/mapper/hoardvg-backuplv rw
! run_guard

write_mountinfo rw,relatime ext4 /dev/mapper/hoardvg-backuplv rw
chmod 0644 "$mount_path/.backup-sentinel"
printf '%s\n' wrong >"$mount_path/.backup-sentinel"
chmod 0444 "$mount_path/.backup-sentinel"
! run_guard

chmod 0644 "$mount_path/.backup-sentinel"
printf '%s\n' 'cc1cedb8-ef22-44b5-b1d0-5ca020d72669' >"$mount_path/.backup-sentinel"
chmod 0664 "$mount_path/.backup-sentinel"
! run_guard

mockbin="$tmpdir/mockbin"
mkdir -p "$mockbin"
cat >"$mockbin/guard-command" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

command_name="${0##*/}"
state=""
if [ -s "$GUARD_TEST_STATE" ]; then
  IFS= read -r state <"$GUARD_TEST_STATE"
fi
printf '%s\n' "$command_name $*" >>"$GUARD_TEST_LOG"

case "$command_name" in
  mountpoint) exit 1 ;;
  find) exit 0 ;;
  chattr)
    case "$1" in
      -i) : >"$GUARD_TEST_STATE" ;;
      +i) printf 'immutable\n' >"$GUARD_TEST_STATE" ;;
      *) exit 2 ;;
    esac
    ;;
  install|chown|chmod)
    [ "$state" != immutable ] || exit 1
    ;;
  lsattr)
    [ "$state" = immutable ] || exit 1
    printf '%s %s\n' '----i-----------------' "${*: -1}"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$mockbin/guard-command"
for command_name in mountpoint find chattr install chown chmod lsattr; do
  ln -s guard-command "$mockbin/$command_name"
done

for host_guard in \
  "$repo_root/host/minis/usr/local/sbin/backups-mountpoint-guard" \
  "$repo_root/host/minis/usr/local/sbin/vault-mountpoint-guard"; do
  guard_state="$tmpdir/$(basename "$host_guard").state"
  guard_log="$tmpdir/$(basename "$host_guard").log"
  fixture_mount="$tmpdir/$(basename "$host_guard").mount"
  mkdir "$fixture_mount"
  : >"$guard_state"
  : >"$guard_log"
  for _ in 1 2; do
    PATH="$mockbin:$PATH" \
    MOUNTPOINT_PATH="$fixture_mount" \
    GUARD_TEST_STATE="$guard_state" \
    GUARD_TEST_LOG="$guard_log" \
      "$host_guard"
  done
  grep -qx immutable "$guard_state"
  [ "$(grep -c -- '^chattr -i ' "$guard_log")" -eq 2 ]
done

echo "mount guard fixture tests passed"
