#!/usr/bin/env bash
# Install the ryze-side vault uploader and generate its dedicated key.
# shellcheck source=runbooks/backups/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools install sftp ssh-keygen ssh-keyscan systemctl timeout
[ "$(hostname -s)" = ryze ] || die "run this step on ryze"
[ "$(id -u)" -eq 1000 ] || die "run this step as ryze's uid-1000 operator"

client_root="$REPO_ROOT/host/ryze"
client_config="$HOME/.config/vault-ingest"
identity="$client_config/id_ed25519"
known_hosts="$client_config/known_hosts"
authorized="$REPO_ROOT/host/minis/etc/ssh/vault-ingest-authorized-keys/vault-ingest-ryze"

install -d -m 0700 "$client_config" "$HOME/.config/systemd/user"
sudo install -D -o root -g root -m 0755 \
  "$client_root/usr/local/bin/vault-ingest" /usr/local/bin/vault-ingest
install -m 0644 \
  "$client_root/etc/systemd/user/vault-ingest-kdbx.service" \
  "$HOME/.config/systemd/user/vault-ingest-kdbx.service"
install -m 0644 \
  "$client_root/etc/systemd/user/vault-ingest-kdbx.timer" \
  "$HOME/.config/systemd/user/vault-ingest-kdbx.timer"

if [ ! -f "$identity" ]; then
  ssh-keygen -q -t ed25519 -N '' -C vault-ingest-ryze -f "$identity"
fi
chmod 0600 "$identity"
mkdir -p "$(dirname "$authorized")"
install -m 0644 "$identity.pub" "$authorized"
ok "dedicated public key recorded at $authorized"

if ! timeout 3 bash -c '</dev/tcp/10.137.20.5/2222' 2>/dev/null; then
  warn "the ingestion listener is not active yet"
  cat <<'EOF'
Commit the new public key, deploy it on minis with 08-install-vault-ingest-server.sh,
then rerun this script to pin the host key and enable the timer.
EOF
  exit 0
fi

scan="$(mktemp)"
trap 'rm -f "$scan"' EXIT
ssh-keyscan -p 2222 -t ed25519 10.137.20.5 2>/dev/null >"$scan"
[ -s "$scan" ] || die "could not read the ingestion listener host key"
ssh-keygen -lf "$scan"
confirm "Does this match minis's trusted ED25519 host-key fingerprint?" \
  || die "host-key fingerprint was not accepted"
install -m 0600 "$scan" "$known_hosts"

systemctl --user daemon-reload
systemctl --user enable --now vault-ingest-kdbx.timer
systemctl --user start vault-ingest-kdbx.service
ok "ryze KDBX ingestion timer is enabled"
