#!/usr/bin/env bash
# Attended, repeatable ACL and destination setup for the Frigate archival copier.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root
require_sudo
require_tools find cut findmnt getfacl getent groupadd grep setfacl stat useradd
[ -t 0 ] || die "Frigate ingestion permissions require an attended TTY"
[ "$(hostname -s)" = minis ] || die "run this setup on minis"

uid=2207
gid=2207
source_dir=/mnt/frigate/exports
vault_root=/mnt/vault
destination=$vault_root/frigate-exports
source_device=/dev/mapper/hoardvg-frigate
source_uuid=0b69665d-53ac-4380-815d-6969713940d6
vault_device=/dev/mapper/vault

sudo mountpoint -q /mnt/frigate || die "/mnt/frigate is not mounted"
[ "$(sudo findmnt --real -n -o SOURCE,FSTYPE -T "$source_dir")" = "$source_device ext4" ] \
  || die "Frigate exports are not on the expected ext4 LV"
[ "$(sudo findmnt --real -n -o UUID -T "$source_dir")" = "$source_uuid" ] \
  || die "Frigate export filesystem UUID does not match the inspected source LV"
sudo mountpoint -q "$vault_root" || die "vault must be unlocked and mounted"
[ "$(sudo findmnt --real -n -o SOURCE,FSTYPE -T "$vault_root")" = "$vault_device ext4" ] \
  || die "vault is not the expected ext4 LV"
sudo test -d "$source_dir" && sudo test ! -L "$source_dir" \
  || die "Frigate export directory is missing or a symlink"
sudo test -d "$destination" && sudo test ! -L "$destination" \
  || die "vault destination is missing or a symlink"
sudo test "$(sudo stat -c '%u:%g:%a' "$vault_root/.vault-sentinel")" = 0:0:444 \
  || die "vault sentinel metadata is invalid"
sudo grep -qxF 'vault-contract-version=3' "$vault_root/.vault-sentinel" \
  || die "vault sentinel is not contract v3"
vault_uuid="$(sudo blkid -s UUID -o value "$vault_device")"
sudo grep -qxF "filesystem-uuid=$vault_uuid" "$vault_root/.vault-sentinel" \
  || die "vault sentinel UUID does not match the mounted filesystem"

echo "Source inventory (type owner:group mode size path):"
sudo find "$source_dir" -maxdepth 1 -printf '%y %u:%g %m %s %p\\n'
echo "Mounts:"
sudo findmnt -T "$source_dir" -o TARGET,SOURCE,FSTYPE,UUID
sudo findmnt -T "$vault_root" -o TARGET,SOURCE,FSTYPE,UUID
echo "Target identity: UID:GID $uid:$gid"
read -r -p 'Type PREPARE-FRIGATE-INGEST to apply these permissions: ' answer
[ "$answer" = PREPARE-FRIGATE-INGEST ] || die "confirmation did not match"

group_entry="$(getent group "$gid" || true)"
if [ -z "$group_entry" ]; then
  sudo groupadd --system --gid "$gid" frigate-ingest
else
  [ "${group_entry%%:*}" = frigate-ingest ] || die "GID $gid belongs to an unexpected group"
fi
user_entry="$(getent passwd "$uid" || true)"
if [ -z "$user_entry" ]; then
  sudo useradd --system --uid "$uid" --gid "$gid" --no-create-home --shell /usr/sbin/nologin frigate-ingest
else
  [ "${user_entry%%:*}" = frigate-ingest ] || die "UID $uid belongs to an unexpected account"
fi
[ "$(getent passwd "$uid" | cut -d: -f4)" = "$gid" ] || die "UID $uid already belongs to an unexpected primary GID"

# Grant traversal/read to current tree and default read/traverse on future entries.
sudo setfacl -R -m "g:$gid:r-X" "$source_dir"
sudo find "$source_dir" -type d -exec setfacl -m "d:g:$gid:r-X" {} +
# A legacy photos directory is mode 0755, so add a UID-specific deny at its
# root; it blocks traversal without changing the ownership or modes of its data.
sudo setfacl -m "u:$uid:---" "$vault_root/photos"
# The vault mount root is 0700. Grant traversal only so the copier can reach
# the sentinel and the explicitly writable archive directory below it.
sudo setfacl -m "u:$uid:--x" "$vault_root"
# The copier identity can write only this directory. Other vault paths remain inaccessible.
sudo chown root:"$gid" "$destination"
sudo chmod 2770 "$destination"
sudo setfacl -b "$destination"
sudo chmod 2770 "$destination"

sudo -u '#2207' test -r "$source_dir" || die "ingest identity cannot read source directory"
sudo -u '#2207' test -r "$vault_root/.backup-credentials/nas-password" \
  && die "ingest identity can read NAS backup credentials"
sudo -u '#2207' test -r "$vault_root/.mail-credentials/gmail-app-password" \
  && die "ingest identity can read mail credentials"
for private in credentials documents photos mail firmware inbox .backup-credentials .mail-credentials .restore-tests; do
  if sudo -u '#2207' test -r "$vault_root/$private"; then die "ingest identity can read vault path $private"; fi
done
while IFS= read -r path; do
  case "$path" in "$destination"|"$vault_root/.vault-sentinel") continue ;; esac
  sudo -u '#2207' test ! -r "$path" || die "ingest identity can read other vault content: $path"
  sudo -u '#2207' test ! -w "$path" || die "ingest identity can write other vault content: $path"
done < <(sudo find "$vault_root" -mindepth 1 -maxdepth 1 -print)
sudo -u '#2207' test -w "$destination" || die "ingest identity cannot write destination"
sudo -u '#2207' test ! -r "$vault_root" || die "ingest identity can list the vault root"
sudo -u '#2207' test ! -w "$vault_root" || die "ingest identity can write the vault root"
for sibling in "$vault_root" "$vault_root/credentials" "$vault_root/mail"; do
  sudo -u '#2207' test ! -w "$sibling" || die "ingest identity can write outside destination: $sibling"
done
ok "Frigate ingestion ACLs installed and checked as UID:GID $uid:$gid"
