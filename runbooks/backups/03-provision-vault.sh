#!/usr/bin/env bash
# Create the new 200 GiB encrypted vault and print its non-secret identities.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools blkid cryptsetup lvcreate lvs mkfs.ext4 vgs
[ -t 0 ] || die "vault provisioning requires an attended TTY"

raw_device=/dev/mapper/hoardvg-vaultlv
mapper=/dev/mapper/vault

sudo lvs hoardvg/vaultlv >/dev/null 2>&1 \
  && die "hoardvg/vaultlv already exists; inspect it instead of re-running provisioning"
[ ! -e "$mapper" ] || die "$mapper already exists"

free_bytes="$(sudo vgs --noheadings --units b --nosuffix -o vg_free hoardvg | awk '{printf "%.0f", $1}')"
[ "$free_bytes" -ge 214748364800 ] \
  || die "hoardvg has less than 200 GiB free"

cat <<'EOF'
This creates hoardvg/vaultlv, formats it as LUKS2, and creates a new ext4 filesystem.
The LUKS passphrase is not stored by this script. Record it on both break-glass cards
before continuing; losing it strands the source filesystem.
EOF
confirm "Create the new 200 GiB encrypted vault LV?" \
  || die "vault creation was not confirmed"

step "Create the vault logical volume"
sudo lvcreate --size 200G --name vaultlv hoardvg

step "Initialize the LUKS2 container"
sudo cryptsetup luksFormat --type luks2 "$raw_device"
sudo cryptsetup open "$raw_device" vault

step "Create the ext4 vault filesystem"
sudo mkfs.ext4 -L vault "$mapper"

luks_uuid="$(sudo cryptsetup luksUUID "$raw_device")"
fs_uuid="$(sudo blkid -s UUID -o value "$mapper")"
[ -n "$luks_uuid" ] && [ -n "$fs_uuid" ] || die "could not read generated UUIDs"

cat <<EOF

Vault storage created. UUIDs are non-secret and must now be committed canonically:

VAULT_LUKS_UUID=$luks_uuid VAULT_FS_UUID=$fs_uuid \\
  ./runbooks/backups/04-install-vault-host-config.sh

The mapper remains open so the next step can validate and mount it.
EOF

