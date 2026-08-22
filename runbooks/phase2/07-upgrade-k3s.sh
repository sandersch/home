#!/usr/bin/env bash
# Attended in-place k3s upgrade to the exact reviewed K3S_VERSION pin.

# shellcheck source=runbooks/phase2/k3s-upgrade-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/k3s-upgrade-lib.sh"

checkpoint=""
snapshot=""
installer=""

upgrade_failed() {
  local status=$?
  [ "$status" -ne 0 ] || return 0
  printf '\nUpgrade did not complete successfully. Evidence has not been removed.\n' >&2
  [ -n "$checkpoint" ] && printf 'Checkpoint: %s\n' "$checkpoint" >&2
  [ -n "$snapshot" ] && printf 'Read-only /opt snapshot: %s\n' "$snapshot" >&2
  if [ -n "$checkpoint" ]; then
    printf 'After diagnosing the failure, roll back with:\n  %s/08-rollback-k3s.sh %s\n' \
      "$(dirname "${BASH_SOURCE[0]}")" "$checkpoint" >&2
  fi
  exit "$status"
}
trap upgrade_failed EXIT

require_not_root
require_sudo
require_tools awk btrfs curl find git kubectl flux realpath sha256sum sqlite3 stat systemctl
assert_hostname_minis
assert_git_clean_and_up_to_date "k3s upgrade"
assert_k3s_service_active
validate_k3s_target "$K3S_VERSION"

source_version="$(installed_k3s_version)"
[ -n "$source_version" ] || die "could not parse the installed k3s version"
relation="$(upgrade_relation "$source_version" "$K3S_VERSION")"
if [ "$relation" = current ]; then
  ok "k3s is already at reviewed target $K3S_VERSION; no changes made"
  trap - EXIT
  exit 0
fi

assert_canonical_k3s_config
assert_k3s_source_files
validate_k3s_database "$K3S_DB_DIR/state.db"
assert_flux_healthy_for_upgrade

cat <<EOF
This will upgrade the single-node cluster from $source_version to $K3S_VERSION.
Flux will remain active and the node will not be drained. The Kubernetes API will
briefly stop; existing workload containers are expected to keep running.
EOF
confirm "Have the latest local backup AND restore validation passed?" \
  || die "local backup/restore confirmation is required"
confirm "Have the latest B2 backup AND restore validation passed?" \
  || die "B2 backup/restore confirmation is required"
confirm "Is the matching k3s server token stored in the password manager?" \
  || die "password-manager token confirmation is required"
confirm "Create checkpoints and upgrade to $K3S_VERSION now?" || die "aborted"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$K3S_VERSION"
snapshot="/opt/.snapshots/pre-k3s-${safe_target}-${timestamp}"
checkpoint="$K3S_CHECKPOINT_ROOT/$timestamp-$safe_target"

step "Download the official k3s installer before downtime"
installer="$(mktemp)"
curl -sfL https://get.k3s.io -o "$installer"
chmod 0700 "$installer"

step "Create the application-state rollback snapshot"
sudo install -d -o root -g root -m 0700 /opt/.snapshots
if sudo test -e "$snapshot"; then
  die "refusing to overwrite existing snapshot: $snapshot"
fi
sudo btrfs subvolume snapshot -r /opt "$snapshot"
ok "created read-only snapshot $snapshot"

step "Stop k3s and create a consistent host checkpoint"
sudo systemctl stop k3s
if systemctl is-active --quiet k3s; then
  die "k3s remained active after stop"
fi
create_upgrade_checkpoint "$checkpoint" "$source_version" "$K3S_VERSION"

step "Install exact reviewed k3s target"
run_official_k3s_installer "$installer" "$K3S_VERSION"

step "Validate upgraded control plane"
assert_k3s_service_active
actual_version="$(installed_k3s_version)"
assert_installed_version_value "$actual_version" "$K3S_VERSION"
assert_kubectl_ready
wait_for_kubelet_version "$K3S_VERSION"
kubectl get --raw=/readyz >/dev/null || die "Kubernetes API /readyz failed"
ok "k3s $K3S_VERSION is active and the API and node are Ready"

rm -f "$installer"
trap - EXIT
cat <<EOF

Upgrade completed. Keep these rollback artifacts through the 24-hour observation:
  $checkpoint
  $snapshot

Run the Phase 2-5 acceptance gates documented in runbooks/phase2/README.md now.
After the 24-hour observation closes, deliberately remove the token-bearing
checkpoint and temporary snapshot using the documented cleanup commands.
EOF
