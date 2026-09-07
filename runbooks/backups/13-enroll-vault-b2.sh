#!/usr/bin/env bash
# Enroll the encrypted vault repository in its dedicated B2 destination.
# This is attended: no credential is placed in git, a Kubernetes Secret, argv, or
# shell history. Run on minis after the B2 bucket and restricted application key exist.
set -Eeuo pipefail
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools restic jq
[ "$(hostname -s)" = minis ] || die "run this step on minis"
sudo test -f /etc/homelab/vault-b2.conf \
  || die "install /etc/homelab/vault-b2.conf with VAULT_B2_REPOSITORY first"
source /etc/homelab/vault-b2.conf
: "${VAULT_B2_REPOSITORY:?VAULT_B2_REPOSITORY is required}"
sudo test -f /mnt/vault/.vault-sentinel \
  || die "unlock and mount /mnt/vault before enrollment"
sudo grep -qxF 'vault-contract-version=2' /mnt/vault/.vault-sentinel \
  || die "vault sentinel contract mismatch"
sudo test -f /mnt/backups/vault/config \
  || die "vault NAS repository is not initialized"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
umask 077
printf 'Enter the new vault B2 repository password: '
read -r -s b2_password
printf '\nConfirm the vault B2 repository password: '
read -r -s b2_password_again
printf '\n'
[ "$b2_password" = "$b2_password_again" ] || die "repository passwords differ"
printf 'B2 application key ID: '
read -r b2_key_id
printf 'B2 application key secret: '
read -r -s b2_key
printf '\n'
[ -n "$b2_key_id" ] && [ -n "$b2_key" ] || die "B2 key fields may not be empty"

printf '%s\n' "$b2_password" >"$tmpdir/password"
if ! AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_key" \
  RESTIC_PASSWORD_FILE="$tmpdir/password" \
  restic -r "$VAULT_B2_REPOSITORY" snapshots >/dev/null 2>&1; then
  AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_key" \
    RESTIC_PASSWORD_FILE="$tmpdir/password" \
    RESTIC_FROM_PASSWORD_FILE=/mnt/vault/.backup-credentials/nas-password \
    restic -r "$VAULT_B2_REPOSITORY" init --from-repo /mnt/backups/vault --copy-chunker-params \
    || die "B2 repository initialization failed; credential files were retained for retry"
else
  log "B2 repository already initialized; preserving its chunker parameters"
fi
AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_key" \
  RESTIC_PASSWORD_FILE="$tmpdir/password" \
  restic -r "$VAULT_B2_REPOSITORY" snapshots --json >/dev/null \
  || die "B2 repository cannot be opened after initialization"

# Persist credentials only after the destination has proved that the new password
# and application key work. A failed enrollment therefore leaves no half-valid
# credential set inside the encrypted vault.
printf '%s\n' "$b2_password" | sudo tee /mnt/vault/.backup-credentials/b2-password >/dev/null
printf '%s\n' "$b2_key_id" | sudo tee /mnt/vault/.backup-credentials/b2-key-id >/dev/null
printf '%s\n' "$b2_key" | sudo tee /mnt/vault/.backup-credentials/b2-application-key >/dev/null
sudo chown root:root /mnt/vault/.backup-credentials/b2-password /mnt/vault/.backup-credentials/b2-key-id /mnt/vault/.backup-credentials/b2-application-key
sudo chmod 0600 /mnt/vault/.backup-credentials/b2-password /mnt/vault/.backup-credentials/b2-key-id /mnt/vault/.backup-credentials/b2-application-key

ok "vault B2 repository initialized; leave restic-vault-copy suspended until the manual copy and restore gates pass"
