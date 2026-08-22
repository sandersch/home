#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
upgrade_script="$script_dir/07-upgrade-k3s.sh"
rollback_script="$script_dir/08-rollback-k3s.sh"

# shellcheck source=runbooks/phase2/k3s-upgrade-lib.sh
source "$script_dir/k3s-upgrade-lib.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if ("$@" >/dev/null 2>&1); then
    fail "$label unexpectedly succeeded"
  fi
}

# Unit tests deliberately replace sudo with a pass-through; production callers
# still require an authenticated sudo session before using these helpers.
sudo() {
  "$@"
}

[ "$K3S_VERSION" = "v1.36.3+k3s1" ] || fail "unexpected target $K3S_VERSION"
[ "$(grep -Fc 'run_official_k3s_installer "$installer" "$K3S_VERSION"' "$upgrade_script")" -eq 1 ] \
  || fail "upgrade script does not pass the canonical pin to the installer"
grep -Fq 'INSTALL_K3S_VERSION="$target"' "$script_dir/k3s-upgrade-lib.sh" \
  || fail "official installer wrapper does not set INSTALL_K3S_VERSION"
[ "$(upgrade_relation "$K3S_VERSION" "$K3S_VERSION")" = current ] \
  || fail "already-current release is not a no-op"
[ "$(upgrade_relation v1.36.2+k3s1 "$K3S_VERSION")" = upgrade ] \
  || fail "expected same-minor patch upgrade was rejected"
[ "$(upgrade_relation v1.35.9+k3s1 "$K3S_VERSION")" = upgrade ] \
  || fail "expected one-minor upgrade was rejected"

expect_failure "malformed target" validate_k3s_target 1.36.3
expect_failure "prerelease target" validate_k3s_target v1.36.3-rc1+k3s1
expect_failure "downgrade" upgrade_relation v1.36.3+k3s1 v1.36.2+k3s1
expect_failure "skipped minor" upgrade_relation v1.34.9+k3s1 v1.36.3+k3s1

systemctl() {
  return 1
}
expect_failure "inactive service" assert_k3s_service_active
unset -f systemctl

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/db"
printf 'token\n' >"$test_root/token"
expect_failure "missing datastore" assert_k3s_source_files "$test_root/db" "$test_root/token"
sqlite3 "$test_root/db/state.db" \
  "CREATE TABLE kine (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO kine(name) VALUES ('test');"
rm "$test_root/token"
expect_failure "missing token" assert_k3s_source_files "$test_root/db" "$test_root/token"
printf 'token\n' >"$test_root/token"
assert_k3s_source_files "$test_root/db" "$test_root/token"
validate_k3s_database "$test_root/db/state.db" >/dev/null

checkpoint_root="$test_root/checkpoints"
checkpoint="$checkpoint_root/good"
mkdir -p \
  "$checkpoint/usr/local/bin" \
  "$checkpoint/etc/systemd/system" \
  "$checkpoint/etc/rancher/k3s" \
  "$checkpoint/var/lib/rancher/k3s/server/db"
printf '#!/bin/sh\nprintf "k3s version v1.36.2+k3s1 (test)\\n"\n' \
  >"$checkpoint/usr/local/bin/k3s"
chmod 0755 "$checkpoint/usr/local/bin/k3s"
printf '[Service]\n' >"$checkpoint/etc/systemd/system/k3s.service"
printf 'kube-controller-manager-arg: []\n' >"$checkpoint/etc/rancher/k3s/config.yaml"
cp "$test_root/db/state.db" "$checkpoint/var/lib/rancher/k3s/server/db/state.db"
printf 'token\n' >"$checkpoint/var/lib/rancher/k3s/server/token"
printf 'source_version=v1.36.2+k3s1\ntarget_version=%s\n' "$K3S_VERSION" >"$checkpoint/metadata"
(
  cd "$checkpoint"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
chmod 0700 "$checkpoint"
resolved="$(validate_checkpoint_path "$checkpoint" "$checkpoint_root")"
[ "$resolved" = "$checkpoint" ] || fail "checkpoint path resolution changed the target"
validate_upgrade_checkpoint "$checkpoint" "$(id -u)" >/dev/null
mkdir -p "$checkpoint/nested"
expect_failure "nested checkpoint path" validate_checkpoint_path "$checkpoint/nested" "$checkpoint_root"
chmod 0755 "$checkpoint"
expect_failure "checkpoint permissions" validate_upgrade_checkpoint "$checkpoint" "$(id -u)"
chmod 0700 "$checkpoint"
printf '# changed\n' >>"$checkpoint/etc/systemd/system/k3s.service"
expect_failure "checkpoint checksum" validate_upgrade_checkpoint "$checkpoint" "$(id -u)"

expect_failure "installer failure" run_official_k3s_installer /bin/false "$K3S_VERSION"
expect_failure "post-restart version mismatch" \
  assert_installed_version_value v1.36.2+k3s1 "$K3S_VERSION"
kubectl() {
  printf 'v1.36.2+k3s1'
}
expect_failure "post-restart kubelet version mismatch" \
  wait_for_kubelet_version "$K3S_VERSION" 0
unset -f kubectl

grep -Fq 'failed-post-upgrade-' "$rollback_script" \
  || fail "rollback does not preserve failed post-upgrade state"
grep -Fq 'validate_upgrade_checkpoint "$checkpoint"' "$rollback_script" \
  || fail "rollback does not validate its checkpoint"

ok "k3s upgrade and rollback safety tests passed"
