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

# Keep staging off persistent storage even when the caller overrides TMPDIR.
[ "$(stat -f -c %T /dev/shm)" = tmpfs ] || die "/dev/shm must be tmpfs"
tmpdir="$(mktemp -d /dev/shm/vault-b2-enroll.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
umask 077
printf 'Enter the new vault B2 repository password: '
read -r -s b2_password
printf '\nConfirm the vault B2 repository password: '
read -r -s b2_password_again
printf '\n'
[ -n "$b2_password" ] && [ "$b2_password" = "$b2_password_again" ] || die "repository passwords differ"
printf 'B2 application key ID: '
read -r b2_key_id
printf 'B2 application key secret: '
read -r -s b2_key
printf '\n'
[ -n "$b2_key_id" ] && [ -n "$b2_key" ] || die "B2 key fields may not be empty"

printf '%s\n' "$b2_password" >"$tmpdir/password"
printf '%s\n' "$b2_key_id" >"$tmpdir/key-id"
printf '%s\n' "$b2_key" >"$tmpdir/application-key"
unset b2_password b2_password_again b2_key_id b2_key

# Only paths and the repository URL cross sudo's argv/logging boundary. Read the
# staged credentials inside the privileged process that can open the NAS password.
sudo bash -s -- "$tmpdir" "$VAULT_B2_REPOSITORY" <<'ROOT'
set -Eeuo pipefail
staging="$1"
repository="$2"
export TMPDIR="$staging"
AWS_ACCESS_KEY_ID="$(cat "$staging/key-id")"
AWS_SECRET_ACCESS_KEY="$(cat "$staging/application-key")"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export RESTIC_PASSWORD_FILE="$staging/password"
# Host commands must not leave vault metadata in a persistent Restic cache.
restic() { command restic --no-cache "$@"; }
# Durable, non-secret intent survives lost credentials and partial enrollment.
# Once contact is possible, local rejection must prove destination absence.
touch /etc/homelab/vault-b2.enrolled
chmod 0600 /etc/homelab/vault-b2.enrolled
if restic -r "$repository" snapshots >/dev/null 2>&1; then
  printf 'B2 repository already initialized; preserving its chunker parameters\n'
else
  result="$?"
  [ "$result" -eq 10 ] || { printf 'Cannot open B2 repository (exit %s)\n' "$result" >&2; exit "$result"; }
  RESTIC_FROM_PASSWORD_FILE=/mnt/vault/.backup-credentials/nas-password \
    restic -r "$repository" init --from-repo /mnt/backups/vault --copy-chunker-params
fi
restic -r "$repository" snapshots --json >/dev/null

# Persist only after proving the destination password and application key work.
install -o root -g root -m 0600 "$staging/password" /mnt/vault/.backup-credentials/b2-password
install -o root -g root -m 0600 "$staging/key-id" /mnt/vault/.backup-credentials/b2-key-id
install -o root -g root -m 0600 "$staging/application-key" /mnt/vault/.backup-credentials/b2-application-key
ROOT

ok "vault B2 repository initialized; leave restic-vault-copy suspended until the manual copy and restore gates pass"
