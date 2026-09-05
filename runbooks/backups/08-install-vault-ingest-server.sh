#!/usr/bin/env bash
# Install the dedicated SFTP listener and vault-side promotion service on minis.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools findmnt getent groupadd head nft ss sshd systemctl tar useradd wc
[ "$(hostname -s)" = minis ] || die "run this step on minis"
sudo /usr/local/sbin/vault-unlock

authorized_source="$REPO_ROOT/host/minis/etc/ssh/vault-ingest-authorized-keys/vault-ingest-ryze"
[ -s "$authorized_source" ] || die "run 07-prepare-ryze-ingest.sh and commit its public key first"

if getent group 2100 >/dev/null; then
  [ "$(getent group 2100 | cut -d: -f1)" = vault-ingest-ryze ] \
    || die "GID 2100 belongs to an unexpected group"
else
  sudo groupadd --gid 2100 vault-ingest-ryze
fi
if getent passwd 2100 >/dev/null; then
  [ "$(getent passwd 2100 | cut -d: -f1)" = vault-ingest-ryze ] \
    || die "UID 2100 belongs to an unexpected user"
else
  sudo useradd --system --uid 2100 --gid 2100 --home-dir /upload \
    --shell /usr/sbin/nologin vault-ingest-ryze
fi

sudo install -d -o root -g root -m 0755 \
  /etc/ssh/vault-ingest-authorized-keys \
  /mnt/vault/inbox/ryze
sudo install -d -o vault-ingest-ryze -g vault-ingest-ryze -m 0700 \
  /mnt/vault/inbox/ryze/upload
sudo install -o root -g root -m 0600 "$authorized_source" \
  /etc/ssh/vault-ingest-authorized-keys/vault-ingest-ryze

sudo install -o root -g root -m 0600 \
  "$REPO_ROOT/host/minis/etc/ssh/sshd_config_vault_ingest" \
  /etc/ssh/sshd_config_vault_ingest
for unit in vault-ingest-sshd.socket vault-ingest-sshd@.service \
  vault-ingest-promote.path vault-ingest-promote.service; do
  sudo install -o root -g root -m 0644 \
    "$REPO_ROOT/host/minis/etc/systemd/system/$unit" "/etc/systemd/system/$unit"
done
sudo install -o root -g root -m 0755 \
  "$REPO_ROOT/host/minis/usr/local/sbin/vault-ingest-promote" \
  /usr/local/sbin/vault-ingest-promote

sudo sshd -t -f /etc/ssh/sshd_config_vault_ingest
effective_sshd="$(sudo sshd -T -f /etc/ssh/sshd_config_vault_ingest \
  -C user=vault-ingest-ryze,host=minis,addr=10.137.30.6)"
grep -qx 'usepam yes' <<<"$effective_sshd" \
  || die "the ingestion listener must use PAM account checks for the locked system identity"
grep -qx 'passwordauthentication no' <<<"$effective_sshd" \
  || die "the ingestion listener unexpectedly permits password authentication"
grep -qx 'kbdinteractiveauthentication no' <<<"$effective_sshd" \
  || die "the ingestion listener unexpectedly permits keyboard-interactive authentication"
grep -qx 'forcecommand internal-sftp -d /upload' <<<"$effective_sshd" \
  || die "the ingestion identity does not have the expected forced SFTP command"
sudo systemd-analyze verify \
  /etc/systemd/system/vault-ingest-sshd.socket \
  /etc/systemd/system/vault-ingest-sshd@.service \
  /etc/systemd/system/vault-ingest-promote.path \
  /etc/systemd/system/vault-ingest-promote.service
sudo nft -c -f "$REPO_ROOT/host/minis/etc/nftables.conf"
sudo install -o root -g root -m 0644 \
  "$REPO_ROOT/host/minis/etc/nftables.conf" /etc/nftables.conf
sudo nft -f /etc/nftables.conf

sudo systemctl daemon-reload
sudo systemctl enable --now vault-ingest-sshd.socket
sudo systemctl start vault-ingest-promote.path
sudo ss -ltn | grep -q '10\.137\.20\.5:2222' \
  || die "the restricted ingestion socket is not listening"
ok "restricted vault ingestion is active on 10.137.20.5:2222"

cat <<'EOF'
Rerun 07-prepare-ryze-ingest.sh on ryze to pin the host key and start the KDBX timer.
Then seed documents once with: /usr/local/bin/vault-ingest documents
EOF
