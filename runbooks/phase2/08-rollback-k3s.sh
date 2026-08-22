#!/usr/bin/env bash
# Restore a validated pre-upgrade k3s checkpoint after an unsuccessful upgrade.

# shellcheck source=runbooks/phase2/k3s-upgrade-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/k3s-upgrade-lib.sh"

[ "$#" -eq 1 ] || die "usage: $0 $K3S_CHECKPOINT_ROOT/<checkpoint>"
require_not_root
require_sudo
require_tools cp find kubectl realpath sha256sum sqlite3 stat systemctl
assert_hostname_minis

checkpoint="$(validate_checkpoint_path "$1")"
validate_upgrade_checkpoint "$checkpoint"
source_version="$(checkpoint_metadata_value "$checkpoint" source_version)"

cat <<EOF
This will stop k3s, preserve the current post-upgrade state inside:
  $checkpoint/failed-post-upgrade-<UTC>
and restore k3s $source_version from:
  $checkpoint
EOF
confirm "Roll back k3s now?" || die "aborted"

failed_state="$checkpoint/failed-post-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -o root -g root -m 0700 "$failed_state"
sudo install -d -o root -g root -m 0700 \
  "$failed_state/etc/systemd/system" \
  "$failed_state/etc/rancher" \
  "$failed_state/var/lib/rancher/k3s/server"

step "Stop k3s and preserve failed post-upgrade state"
sudo systemctl stop k3s
if systemctl is-active --quiet k3s; then
  die "k3s remained active after stop"
fi
if sudo test -e "$K3S_BINARY"; then
  sudo install -D -o root -g root -m 0755 "$K3S_BINARY" "$failed_state/usr/local/bin/k3s"
else
  warn "post-upgrade k3s binary is missing"
fi
if sudo test -e "$K3S_UNIT"; then
  sudo cp -a "$K3S_UNIT" "$failed_state/etc/systemd/system/k3s.service"
else
  warn "post-upgrade systemd unit is missing"
fi
if sudo test -e "$K3S_ENV"; then
  sudo cp -a "$K3S_ENV" "$failed_state/etc/systemd/system/k3s.service.env"
fi
if sudo test -e "$K3S_CONFIG_DIR"; then
  sudo cp -a "$K3S_CONFIG_DIR" "$failed_state/etc/rancher/k3s"
else
  warn "post-upgrade k3s config directory is missing"
fi
if sudo test -e "$K3S_DB_DIR"; then
  sudo cp -a "$K3S_DB_DIR" "$failed_state/var/lib/rancher/k3s/server/db"
else
  warn "post-upgrade datastore directory is missing"
fi
if sudo test -e "$K3S_TOKEN"; then
  sudo cp -a "$K3S_TOKEN" "$failed_state/var/lib/rancher/k3s/server/token"
else
  warn "post-upgrade server token is missing"
fi
sudo chown -R root:root "$failed_state"
sudo chmod 0700 "$failed_state"

step "Restore validated pre-upgrade checkpoint"
sudo install -D -o root -g root -m 0755 \
  "$checkpoint/usr/local/bin/k3s" "$K3S_BINARY"
sudo cp -a "$checkpoint/etc/systemd/system/k3s.service" "$K3S_UNIT"
if [ -f "$checkpoint/etc/systemd/system/k3s.service.env" ]; then
  sudo cp -a "$checkpoint/etc/systemd/system/k3s.service.env" "$K3S_ENV"
else
  sudo rm -f "$K3S_ENV"
fi
sudo rm -rf "$K3S_CONFIG_DIR"
sudo cp -a "$checkpoint/etc/rancher/k3s" "$K3S_CONFIG_DIR"
sudo rm -rf "$K3S_DB_DIR"
sudo cp -a "$checkpoint/var/lib/rancher/k3s/server/db" "$K3S_DB_DIR"
sudo cp -a "$checkpoint/var/lib/rancher/k3s/server/token" "$K3S_TOKEN"
sudo systemctl daemon-reload
sudo systemctl start k3s

step "Validate rollback"
assert_k3s_service_active
actual_version="$(installed_k3s_version)"
assert_installed_version_value "$actual_version" "$source_version"
assert_kubectl_ready
kubectl get --raw=/readyz >/dev/null || die "Kubernetes API /readyz failed after rollback"
ok "rollback restored k3s $source_version and node minis is Ready"
warn "failed post-upgrade state retained at $failed_state"
