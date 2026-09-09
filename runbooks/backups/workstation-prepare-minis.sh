#!/usr/bin/env bash
# Attended host preparation; no repository initialization or schedules enabled.
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(hostname -s)" = minis ] || { echo 'run on minis' >&2; exit 1; }
[ -t 0 ] || { echo 'attended terminal required' >&2; exit 1; }
identity="$(findmnt -rn -o SOURCE,FSTYPE --mountpoint /mnt/backups)"
[ "$identity" = '/dev/mapper/hoardvg-backuplv ext4' ] \
  || { echo 'backup mount identity mismatch' >&2; exit 1; }
[ "$(sudo stat -c '%u:%g:%a' /mnt/backups/.backup-sentinel)" = 0:0:444 ] \
  || { echo 'backup sentinel metadata mismatch' >&2; exit 1; }
[ "$(sudo head -n1 /mnt/backups/.backup-sentinel)" = cc1cedb8-ef22-44b5-b1d0-5ca020d72669 ] \
  || { echo 'backup sentinel UUID mismatch' >&2; exit 1; }
free="$(df -B1 --output=avail /mnt/backups | awk 'NR==2 {print $1}')"
[ "$free" -ge 268435456000 ] || { echo 'less than combined 250 GiB workstation caps free' >&2; exit 1; }
sudo install -d -o root -g root -m 0700 /mnt/backups/.control
sudo install -d -o root -g root -m 0755 /mnt/backups/workstations
for client in ryze m5c; do
  # Existing repositories must be audited, never recursively re-owned here.
  path="/mnt/backups/workstations/$client"
  if sudo test -e "$path"; then
    [ "$(sudo stat -c '%u:%g:%a' "$path")" = 65534:65534:700 ] \
      || { echo "$path has unexpected metadata" >&2; exit 1; }
  else
    sudo install -d -o 65534 -g 65534 -m 0700 "$path"
  fi
  sudo install -d -o root -g root -m 0700 "/mnt/backups/.control/workstation-$client"
done

printf 'Confirm m5c DHCP reservation 10.137.30.7, conflict check and Wi-Fi MAC (type the confirmed MAC): '
read -r mac
[ "$mac" = aa:9a:b7:f2:ea:2d ] \
  || { echo 'MAC differs from inventory; update and review inventory before proceeding' >&2; exit 1; }
printf 'Confirm those network checks passed and the reservation belongs to m5c (type yes): '
read -r confirmed
[ "$confirmed" = yes ] || exit 1
authorized="$repo_root/host/minis/etc/ssh/vault-ingest-authorized-keys/vault-ingest-m5c"
[ -s "$authorized" ] || { echo 'commit dedicated m5c public ingestion key first' >&2; exit 1; }
for database in passwd group; do
  entry="$(getent "$database" 2101 || true)"
  [ -z "$entry" ] || [ "${entry%%:*}" = vault-ingest-m5c ] \
    || { echo "2101 already assigned in $database" >&2; exit 1; }
done
getent group vault-ingest-m5c >/dev/null || sudo groupadd --gid 2101 vault-ingest-m5c
getent passwd vault-ingest-m5c >/dev/null || sudo useradd --system --uid 2101 --gid 2101 \
  --home-dir /upload --shell /usr/sbin/nologin vault-ingest-m5c
sudo /usr/local/sbin/vault-unlock
sudo install -d -o root -g root -m 0755 /mnt/vault/inbox/m5c
sudo install -d -o 2101 -g 2101 -m 0700 /mnt/vault/inbox/m5c/upload
sudo install -d -o root -g root -m 0700 /mnt/vault/documents/m5c
sudo install -o root -g root -m 0644 "$authorized" /etc/ssh/vault-ingest-authorized-keys/vault-ingest-m5c
"$repo_root/runbooks/backups/08-install-vault-ingest-server.sh"
sudo install -o root -g root -m 0644 \
  "$repo_root/host/minis/etc/systemd/system/vault-ingest-promote.timer" \
  /etc/systemd/system/vault-ingest-promote.timer
sudo systemctl daemon-reload
echo 'Host paths and identities prepared; repository initialization and timers remain attended steps.'
