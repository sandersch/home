#!/usr/bin/env bash
# Record generated vault UUIDs, install canonical host configuration, and seed credentials.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools blkid chattr cryptsetup findmnt install lsattr mountpoint systemctl
[ -t 0 ] || die "vault host configuration requires an attended TTY"
: "${VAULT_LUKS_UUID:?set VAULT_LUKS_UUID from 03-provision-vault.sh}"
: "${VAULT_FS_UUID:?set VAULT_FS_UUID from 03-provision-vault.sh}"

raw_device=/dev/mapper/hoardvg-vaultlv
mapper=/dev/mapper/vault
vault_mount=/mnt/vault
host_homelab="$REPO_ROOT/host/minis/etc/homelab"
canonical_config="$host_homelab/vault.conf"
canonical_crypttab="$REPO_ROOT/host/minis/etc/crypttab"
canonical_fstab="$REPO_ROOT/host/minis/etc/fstab"

[ "$(sudo cryptsetup luksUUID "$raw_device")" = "$VAULT_LUKS_UUID" ] \
  || die "the raw LV does not match VAULT_LUKS_UUID"
[ -e "$mapper" ] || die "$mapper is not open; re-open it with cryptsetup"
[ "$(sudo blkid -s TYPE -o value "$mapper")" = ext4 ] \
  || die "$mapper is not ext4"
[ "$(sudo blkid -s UUID -o value "$mapper")" = "$VAULT_FS_UUID" ] \
  || die "$mapper does not match VAULT_FS_UUID"

step "Record canonical non-secret vault identities"
mkdir -p "$host_homelab"
config_tmp="$(mktemp)"
crypttab_tmp="$(mktemp)"
fstab_tmp="$(mktemp)"
sentinel_tmp=""
credential_tmp=""
trap 'rm -f "$config_tmp" "$crypttab_tmp" "$fstab_tmp" "$sentinel_tmp" "$credential_tmp"' EXIT
printf 'VAULT_LUKS_UUID=%s\nVAULT_FS_UUID=%s\n' \
  "$VAULT_LUKS_UUID" "$VAULT_FS_UUID" >"$config_tmp"
install -m 0644 "$config_tmp" "$canonical_config"

if [ -f "$canonical_crypttab" ]; then
  awk '$1 != "vault" {print}' "$canonical_crypttab" >"$crypttab_tmp"
else
  printf '# <target name>\t<source device>\t<key file>\t<options>\n' >"$crypttab_tmp"
fi
printf 'vault\tUUID=%s\tnone\tluks,noauto\n' "$VAULT_LUKS_UUID" >>"$crypttab_tmp"
install -m 0644 "$crypttab_tmp" "$canonical_crypttab"

awk '$2 != "/mnt/vault" {print}' "$canonical_fstab" >"$fstab_tmp"
printf '/dev/mapper/vault /mnt/vault ext4 defaults,noauto,nofail 0 2\n' >>"$fstab_tmp"
install -m 0644 "$fstab_tmp" "$canonical_fstab"

step "Install vault host configuration"
sudo install -D -o root -g root -m 0644 "$canonical_config" /etc/homelab/vault.conf
sudo install -o root -g root -m 0644 "$canonical_crypttab" /etc/crypttab
sudo install -o root -g root -m 0644 "$canonical_fstab" /etc/fstab
sudo install -D -o root -g root -m 0755 \
  "$REPO_ROOT/host/minis/usr/local/sbin/vault-mountpoint-guard" \
  /usr/local/sbin/vault-mountpoint-guard
sudo install -D -o root -g root -m 0755 \
  "$REPO_ROOT/host/minis/usr/local/sbin/vault-unlock" \
  /usr/local/sbin/vault-unlock
sudo install -D -o root -g root -m 0644 \
  "$REPO_ROOT/host/minis/etc/systemd/system/vault-mountpoint-guard.service" \
  /etc/systemd/system/vault-mountpoint-guard.service
sudo systemctl daemon-reload

if mountpoint -q "$vault_mount"; then
  die "$vault_mount is already mounted; inspect it before initialization"
fi
sudo chattr -i "$vault_mount" 2>/dev/null || true
sudo install -d -o root -g root -m 0555 "$vault_mount"
sudo /usr/local/sbin/vault-mountpoint-guard
sudo mount "$vault_mount"

step "Initialize the vault filesystem contract"
sudo chown root:root "$vault_mount"
sudo chmod 0711 "$vault_mount"
sentinel_tmp="$(mktemp)"
printf 'vault-contract-version=1\nfilesystem-uuid=%s\n' "$VAULT_FS_UUID" >"$sentinel_tmp"
sudo install -o root -g root -m 0444 "$sentinel_tmp" "$vault_mount/.vault-sentinel"
sudo install -d -o root -g root -m 0700 \
  "$vault_mount/.backup-credentials" \
  "$vault_mount/credentials" \
  "$vault_mount/credentials/strongbox" \
  "$vault_mount/documents" \
  "$vault_mount/documents/ryze" \
  "$vault_mount/photos" \
  "$vault_mount/mail" \
  "$vault_mount/firmware" \
  "$vault_mount/frigate-exports" \
  "$vault_mount/inbox" \
  "$vault_mount/.restore-tests"

read -r -s -p 'Vault NAS Restic password: ' restic_password
printf '\n' >&2
read -r -s -p 'Repeat vault NAS Restic password: ' restic_password_confirm
printf '\n' >&2
[ -n "$restic_password" ] && [ "$restic_password" = "$restic_password_confirm" ] \
  || die "Restic passwords were empty or did not match"
credential_tmp="$(mktemp /dev/shm/vault-restic-password.XXXXXX)"
chmod 0600 "$credential_tmp"
printf '%s' "$restic_password" >"$credential_tmp"
unset restic_password restic_password_confirm
sudo install -o root -g root -m 0600 \
  "$credential_tmp" "$vault_mount/.backup-credentials/nas-password"

sudo systemctl enable vault-mountpoint-guard.service >/dev/null
sudo /usr/local/sbin/vault-unlock

cat <<'EOF'

Vault host configuration is installed and the filesystem is mounted.
Review and commit the generated non-secret files under host/minis/etc before any
Kubernetes vault workload is deployed. Do not continue until both sealed break-glass
records contain and have verified the LUKS and vault NAS Restic passwords.
EOF
