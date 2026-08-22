#!/usr/bin/env bash
# Shared safety and validation helpers for attended k3s upgrade/rollback.

# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly K3S_CHECKPOINT_ROOT="/var/lib/rancher/k3s-upgrade-checkpoints"
readonly K3S_BINARY="/usr/local/bin/k3s"
readonly K3S_UNIT="/etc/systemd/system/k3s.service"
readonly K3S_ENV="/etc/systemd/system/k3s.service.env"
readonly K3S_CONFIG_DIR="/etc/rancher/k3s"
readonly K3S_DB_DIR="/var/lib/rancher/k3s/server/db"
readonly K3S_TOKEN="/var/lib/rancher/k3s/server/token"

parse_k3s_version() {
  local version="$1"
  if [[ "$version" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)\+k3s([1-9][0-9]*)$ ]]; then
    printf '%s %s %s %s\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi
  return 1
}

validate_k3s_target() {
  parse_k3s_version "$1" >/dev/null \
    || die "invalid stable k3s target '$1'; expected vMAJOR.MINOR.PATCH+k3sN"
}

upgrade_relation() {
  local source="$1" target="$2"
  local source_parts target_parts
  local s_major s_minor s_patch s_k3s t_major t_minor t_patch t_k3s

  source_parts="$(parse_k3s_version "$source")" \
    || die "installed k3s version '$source' is not a stable release"
  target_parts="$(parse_k3s_version "$target")" \
    || die "target k3s version '$target' is not a stable release"
  read -r s_major s_minor s_patch s_k3s <<<"$source_parts"
  read -r t_major t_minor t_patch t_k3s <<<"$target_parts"

  if [ "$source" = "$target" ]; then
    printf 'current\n'
    return 0
  fi
  [ "$t_major" -eq "$s_major" ] \
    || die "major-version changes are not supported ($source -> $target)"
  [ "$t_minor" -ge "$s_minor" ] \
    || die "k3s downgrade is not allowed ($source -> $target)"
  [ $((t_minor - s_minor)) -le 1 ] \
    || die "cannot skip a Kubernetes minor ($source -> $target)"
  if [ "$t_minor" -eq "$s_minor" ]; then
    if [ "$t_patch" -lt "$s_patch" ] \
      || { [ "$t_patch" -eq "$s_patch" ] && [ "$t_k3s" -le "$s_k3s" ]; }; then
      die "k3s downgrade is not allowed ($source -> $target)"
    fi
  fi
  printf 'upgrade\n'
}

installed_k3s_version() {
  k3s --version | awk 'NR == 1 && $1 == "k3s" && $2 == "version" { print $3 }'
}

assert_k3s_service_active() {
  systemctl is-active --quiet k3s || die "k3s service is not active"
}

assert_k3s_source_files() {
  local db_dir="${1:-$K3S_DB_DIR}" token="${2:-$K3S_TOKEN}"
  sudo test -s "$db_dir/state.db" || die "SQLite datastore is missing or empty: $db_dir/state.db"
  sudo test -s "$token" || die "k3s server token is missing or empty: $token"
}

validate_k3s_database() {
  local database="$1" integrity kine_rows
  sudo test -s "$database" || die "SQLite datastore is missing or empty: $database"
  integrity="$(sudo sqlite3 -readonly "$database" 'PRAGMA integrity_check;')" \
    || die "could not run SQLite integrity_check on $database"
  [ "$integrity" = "ok" ] || die "SQLite integrity_check failed for $database: $integrity"
  kine_rows="$(sudo sqlite3 -readonly "$database" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='kine';")" \
    || die "could not inspect kine schema in $database"
  [ "$kine_rows" = "1" ] || die "required kine table is missing from $database"
  kine_rows="$(sudo sqlite3 -readonly "$database" 'SELECT COUNT(*) FROM kine;')" \
    || die "could not inspect kine data in $database"
  [ "$kine_rows" -gt 0 ] || die "kine table contains no data in $database"
  ok "validated SQLite integrity, kine schema, and nonempty kine data"
}

assert_canonical_k3s_config() {
  sudo cmp -s "$HOST_ETC/rancher/k3s/config.yaml" "$K3S_CONFIG_DIR/config.yaml" \
    || die "live k3s config does not match host/minis/etc/rancher/k3s/config.yaml"
  ok "live k3s server config matches the canonical file"
}

assert_flux_healthy_for_upgrade() {
  assert_kubectl_ready
  flux check >/dev/null || die "flux check failed"
  kubectl wait --for=condition=ready kustomization --all -A --timeout=30s >/dev/null \
    || die "one or more Flux Kustomizations are not Ready"
  kubectl wait --for=condition=ready helmrelease --all -A --timeout=30s >/dev/null \
    || die "one or more HelmReleases are not Ready"
  ok "node, Flux Kustomizations, and HelmReleases are healthy"
}

write_checkpoint_metadata() {
  local checkpoint="$1" source_version="$2" target_version="$3"
  sudo tee "$checkpoint/metadata" >/dev/null <<EOF
source_version=$source_version
target_version=$target_version
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
EOF
  sudo chmod 0600 "$checkpoint/metadata"
}

create_upgrade_checkpoint() {
  local checkpoint="$1" source_version="$2" target_version="$3"

  if sudo test -e "$checkpoint"; then
    die "refusing to overwrite existing checkpoint: $checkpoint"
  fi
  sudo install -d -o root -g root -m 0700 "$K3S_CHECKPOINT_ROOT" "$checkpoint"
  sudo install -d -o root -g root -m 0700 \
    "$checkpoint/etc/systemd/system" \
    "$checkpoint/etc/rancher" \
    "$checkpoint/var/lib/rancher/k3s/server"
  write_checkpoint_metadata "$checkpoint" "$source_version" "$target_version"
  sudo install -D -o root -g root -m 0755 "$K3S_BINARY" "$checkpoint/usr/local/bin/k3s"
  sudo cp -a "$K3S_UNIT" "$checkpoint/etc/systemd/system/k3s.service"
  if sudo test -e "$K3S_ENV"; then
    sudo cp -a "$K3S_ENV" "$checkpoint/etc/systemd/system/k3s.service.env"
  fi
  sudo cp -a "$K3S_CONFIG_DIR" "$checkpoint/etc/rancher/k3s"
  sudo cp -a "$K3S_DB_DIR" "$checkpoint/var/lib/rancher/k3s/server/db"
  sudo cp -a "$K3S_TOKEN" "$checkpoint/var/lib/rancher/k3s/server/token"
  sudo chown -R root:root "$checkpoint"
  sudo chmod 0700 "$checkpoint"
  sudo sh -c "cd '$checkpoint' && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS"
  sudo chmod 0600 "$checkpoint/SHA256SUMS"
  validate_k3s_database "$checkpoint/var/lib/rancher/k3s/server/db/state.db"
  ok "created root-owned upgrade checkpoint $checkpoint"
}

validate_checkpoint_path() {
  local candidate="$1" root="${2:-$K3S_CHECKPOINT_ROOT}" resolved resolved_root
  resolved_root="$(sudo realpath -e "$root")" || die "checkpoint root does not exist: $root"
  resolved="$(sudo realpath -e "$candidate")" || die "checkpoint does not exist: $candidate"
  [ "$(dirname "$resolved")" = "$resolved_root" ] \
    || die "checkpoint must be a direct child of $resolved_root"
  [ -d "$resolved" ] || die "checkpoint is not a directory: $resolved"
  printf '%s\n' "$resolved"
}

checkpoint_metadata_value() {
  local checkpoint="$1" key="$2"
  sudo sed -n "s/^${key}=//p" "$checkpoint/metadata"
}

validate_upgrade_checkpoint() {
  local checkpoint="$1" expected_uid="${2:-0}" expected_owner
  local source_version target_version binary_version relation
  sudo test -f "$checkpoint/metadata" || die "checkpoint metadata is missing"
  sudo test -f "$checkpoint/SHA256SUMS" || die "checkpoint checksums are missing"
  sudo test -x "$checkpoint/usr/local/bin/k3s" || die "checkpoint k3s binary is missing"
  sudo test -f "$checkpoint/etc/systemd/system/k3s.service" || die "checkpoint systemd unit is missing"
  sudo test -f "$checkpoint/etc/rancher/k3s/config.yaml" || die "checkpoint k3s config is missing"
  sudo test -s "$checkpoint/var/lib/rancher/k3s/server/token" || die "checkpoint token is missing"
  expected_owner="$(sudo stat -c '%u:%g:%a' "$checkpoint")"
  [ "$expected_owner" = "$expected_uid:$expected_uid:700" ] \
    || die "checkpoint must be owned by root:root with mode 0700 (found $expected_owner)"
  (cd "$checkpoint" && sudo sha256sum --check --strict SHA256SUMS >/dev/null) \
    || die "checkpoint checksum validation failed"
  validate_k3s_database "$checkpoint/var/lib/rancher/k3s/server/db/state.db"
  source_version="$(checkpoint_metadata_value "$checkpoint" source_version)"
  target_version="$(checkpoint_metadata_value "$checkpoint" target_version)"
  validate_k3s_target "$source_version"
  validate_k3s_target "$target_version"
  relation="$(upgrade_relation "$source_version" "$target_version")"
  [ "$relation" = upgrade ] || die "checkpoint does not record a forward k3s upgrade"
  binary_version="$(sudo "$checkpoint/usr/local/bin/k3s" --version \
    | awk 'NR == 1 && $1 == "k3s" && $2 == "version" { print $3 }')"
  assert_installed_version_value "$binary_version" "$source_version"
  ok "checkpoint binary matches recorded source version $source_version"
}

run_official_k3s_installer() {
  local installer="$1" target="$2"
  sudo env INSTALL_K3S_VERSION="$target" sh "$installer" \
    --disable traefik --disable servicelb --node-name minis
}

assert_installed_version_value() {
  local actual="$1" expected="$2"
  [ "$actual" = "$expected" ] \
    || die "installed k3s version is '$actual', expected '$expected'"
}
