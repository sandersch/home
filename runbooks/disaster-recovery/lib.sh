#!/usr/bin/env bash
# Shared helpers for the attended full-state disaster-recovery runbook.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

RECOVERY_STATE_DIR=/var/lib/homelab-recovery
RECOVERY_STATE_FILE="$RECOVERY_STATE_DIR/state"
export RECOVERY_IMAGE=ghcr.io/sandersch/restic-backup:0.19.0-1

backup_contract_config() {
  printf '%s/infrastructure/monitoring/restic-nas-config.yaml\n' "$REPO_ROOT"
}

backup_contract_version() {
  yq -er '.data.BACKUP_CONTRACT_VERSION' "$(backup_contract_config)"
}

required_sqlite_databases() {
  yq -er '.data.REQUIRED_SQLITE_DATABASES' "$(backup_contract_config)" \
    | sed '/^[[:space:]]*$/d'
}

assert_hot_dump_contract() {
  local hot_dumps="$1" expected_version actual_version
  local expected_inventory actual_inventory created_at relative required_count

  expected_version="$(backup_contract_version)"
  sudo test -s "$hot_dumps/contract-version" \
    || die "selected snapshot has no backup contract marker"
  actual_version="$(sudo cat "$hot_dumps/contract-version")"
  [ "$actual_version" = "$expected_version" ] \
    || die "selected snapshot uses backup contract $actual_version, expected $expected_version"

  sudo test -s "$hot_dumps/required-sqlite-databases.txt" \
    || die "selected snapshot has no required SQLite inventory"
  expected_inventory="$(required_sqlite_databases)"
  actual_inventory="$(sudo cat "$hot_dumps/required-sqlite-databases.txt")"
  [ "$actual_inventory" = "$expected_inventory" ] \
    || die "selected snapshot's required SQLite inventory differs from the current recovery contract"

  required_count=0
  while IFS= read -r relative; do
    sudo test -s "$hot_dumps/sqlite/${relative}.sqlite-backup" \
      || die "selected snapshot is missing required SQLite hot backup: $relative"
    required_count=$((required_count + 1))
  done < <(required_sqlite_databases)
  [ "$required_count" -gt 0 ] || die "current required SQLite inventory is empty"

  sudo test -s "$hot_dumps/home-assistant/home-assistant.tar" \
    || die "selected snapshot has no canonical Home Assistant managed backup"
  sudo tar -tf "$hot_dumps/home-assistant/home-assistant.tar" >/dev/null \
    || die "selected snapshot's Home Assistant managed backup is not a readable tar archive"

  sudo test -s "$hot_dumps/romm/romm.sql" \
    || die "selected snapshot has no RomM logical dump"
  sudo grep -Eq '^CREATE TABLE ' "$hot_dumps/romm/romm.sql" \
    || die "selected snapshot's RomM logical dump contains no CREATE TABLE statements"

  sudo test -s "$hot_dumps/export-created-at" \
    || die "selected snapshot has no export completion timestamp"
  created_at="$(sudo cat "$hot_dumps/export-created-at")"
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "selected snapshot has an invalid export completion timestamp: $created_at"

  ok "backup contract $actual_version contains $required_count required SQLite exports, Home Assistant archive, and RomM dump"
}

require_recovery_source() {
  case "${RECOVERY_SOURCE:-}" in
    nas|b2) ;;
    *) die "set RECOVERY_SOURCE=nas or RECOVERY_SOURCE=b2" ;;
  esac
}

require_recovery_snapshot() {
  [ -n "${RECOVERY_SNAPSHOT:-}" ] \
    || die "set RECOVERY_SNAPSHOT to a full snapshot ID printed by 01-list-snapshots.sh"
  [[ "$RECOVERY_SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] \
    || die "RECOVERY_SNAPSHOT must be a full 64-character lowercase Restic snapshot ID"
}

recovery_stage_root() {
  local candidate
  if [ -n "${RECOVERY_STAGE_ROOT:-}" ]; then
    candidate="$RECOVERY_STAGE_ROOT"
  elif [ "${RECOVERY_SOURCE:-}" = nas ]; then
    candidate=/mnt/backups
  else
    candidate=/mnt/media
  fi
  readlink -f -- "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
}

recovery_stage_dir() {
  local root
  require_recovery_snapshot
  root="$(recovery_stage_root)"
  printf '%s/homelab-recovery/%s\n' "${root%/}" "$RECOVERY_SNAPSHOT"
}

assert_safe_stage_root() {
  local root source source_real opt_real target
  root="$(recovery_stage_root)"
  [[ "$root" = /* ]] || die "RECOVERY_STAGE_ROOT must be an absolute path"
  [[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "RECOVERY_STAGE_ROOT contains unsupported characters: $root"
  case "$root" in
    /|/boot|/home|/opt|/var|/mnt|/mnt/backups/opt)
      die "refusing unsafe recovery staging root: $root"
      ;;
  esac

  timeout 20 ls -la "$root" >/dev/null \
    || die "recovery staging root is not readable: $root"
  mountpoint -q "$root" || die "recovery staging root must itself be a mounted filesystem: $root"
  source="$(findmnt -n -o SOURCE --target "$root")"
  target="$(findmnt -n -o TARGET --target "$root")"
  [ "$target" = "$root" ] || die "$root resolves to mount target $target, expected an exact mountpoint"
  source_real="$(readlink -f -- "$source" 2>/dev/null || true)"
  opt_real="$(readlink -f -- /dev/mapper/vg0-opt 2>/dev/null || true)"
  [ -n "$source_real" ] || die "cannot resolve recovery staging source $source"
  [ -n "$opt_real" ] || die "cannot resolve /opt source /dev/mapper/vg0-opt"
  [ "$source_real" != "$opt_real" ] || die "recovery staging must not share the /opt filesystem"
  case "$root" in
    /mnt/backups)
      assert_direct_mount_layout /mnt/backups /dev/mapper/hoardvg-backuplv \
        cc1cedb8-ef22-44b5-b1d0-5ca020d72669
      ;;
    /mnt/media)
      assert_direct_mount_layout /mnt/media /dev/mapper/hoardvg-medialv \
        0a94d86c-76a0-44b5-bc52-930d97ab155f
      ;;
  esac
  ok "recovery staging root is mounted independently at $root ($source)"
}

assert_opt_mount() {
  assert_mount_layout /opt /dev/mapper/vg0-opt btrfs
}

assert_recovery_repo_files() {
  local path
  for path in \
    clusters/minis/apps.yaml \
    clusters/minis/monitoring.yaml \
    infrastructure/monitoring/restic-nas.sops.yaml \
    infrastructure/monitoring/restic-b2.sops.yaml \
    apps/media/romm/romm.sops.yaml; do
    [ -f "$REPO_ROOT/$path" ] || die "missing recovery input: $path"
  done
  [ -f "$REPO_ROOT/age.key" ] \
    || die "restore the existing age.key from the password manager to $REPO_ROOT/age.key"
  [ "$(stat -c '%a' "$REPO_ROOT/age.key")" = 600 ] \
    || die "$REPO_ROOT/age.key must be mode 600"
  ok "recovery manifests and restored age key are present"
}

git_suspend_value() {
  local path="$1" revision="${2:-worktree}"
  if [ "$revision" = worktree ]; then
    yq -r '.spec.suspend // false' "$REPO_ROOT/$path"
  else
    git -C "$REPO_ROOT" show "$revision:$path" | yq -r '.spec.suspend // false'
  fi
}

assert_git_guard() {
  local target="$1" expected="$2" path actual
  path="clusters/minis/$target.yaml"
  actual="$(git_suspend_value "$path" worktree)"
  [ "$actual" = "$expected" ] \
    || die "$path has spec.suspend=$actual, expected $expected"
  actual="$(git_suspend_value "$path" HEAD)"
  [ "$actual" = "$expected" ] \
    || die "committed $path has spec.suspend=$actual, expected $expected"
  ok "$target git guard is $expected in the worktree and HEAD"
}

assert_git_clean_and_synced() {
  local status upstream counts ahead behind
  status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
  [ -z "$status" ] || {
    printf '%s\n' "$status" >&2
    die "git worktree must be clean; ignored age.key is allowed"
  }
  upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$upstream" ] || die "current branch has no configured upstream"
  git -C "$REPO_ROOT" fetch --prune
  counts="$(git -C "$REPO_ROOT" rev-list --left-right --count HEAD..."$upstream")"
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  [ "$ahead" = 0 ] || die "HEAD has $ahead unpushed commit(s) relative to $upstream"
  [ "$behind" = 0 ] || die "HEAD is $behind commit(s) behind $upstream"
  ok "git worktree is clean and synchronized with $upstream"
}

assert_live_guard() {
  local name="$1" expected="$2" actual
  kubectl -n flux-system get kustomization "$name" >/dev/null 2>&1 \
    || die "live Flux Kustomization $name does not exist"
  actual="$(kubectl -n flux-system get kustomization "$name" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  if [ "$expected" = true ]; then
    [ "$actual" = true ] \
      || die "live Flux Kustomization $name must be suspended"
  else
    [ "$actual" != true ] \
      || die "live Flux Kustomization $name is still suspended"
  fi
  ok "live Flux Kustomization $name suspend state is $expected"
}

assert_no_stateful_workloads() {
  local app_controllers active_pods active_jobs backup_cronjobs
  app_controllers="$(kubectl get \
    deployments.apps,statefulsets.apps,daemonsets.apps,replicasets.apps,jobs.batch,cronjobs.batch \
    -A -o json | jq -r '
      [.items[] |
        select(.metadata.namespace == "media" or
               .metadata.namespace == "frigate" or
               .metadata.namespace == "home-assistant" or
               .metadata.namespace == "mqtt" or
               .metadata.namespace == "zigbee2mqtt") |
        select((.kind == "Job" and .metadata.name == "romm-database-recovery") | not) |
        "\(.kind)/\(.metadata.namespace)/\(.metadata.name)"] | .[]
    ')"
  [ -z "$app_controllers" ] || {
    printf '%s\n' "$app_controllers" >&2
    die "application workload controllers still exist and could recreate pods during recovery"
  }

  active_pods="$(kubectl get pods -A -o json | jq -r '
    [.items[] |
      select(.metadata.namespace == "media" or
             .metadata.namespace == "frigate" or
             .metadata.namespace == "home-assistant" or
             .metadata.namespace == "mqtt" or
             .metadata.namespace == "zigbee2mqtt") |
      select(any(.metadata.ownerReferences[]?;
        .kind == "Job" and .name == "romm-database-recovery") | not) |
      select(.status.phase != "Succeeded" and .status.phase != "Failed") |
      "\(.metadata.namespace)/\(.metadata.name)"] | .[]
  ')"
  [ -z "$active_pods" ] || {
    printf '%s\n' "$active_pods" >&2
    die "stateful application pods are active; this full restore requires an offline /opt"
  }

  active_jobs=''
  backup_cronjobs=''
  if [ -n "$(kubectl get namespace monitoring -o name --ignore-not-found)" ]; then
    active_jobs="$(kubectl -n monitoring get jobs -o json | jq -r '
      [.items[] |
        select((.status.active // 0) > 0) |
        select(.metadata.name != "restic-recovery-list") |
        select(.metadata.name != "restic-full-recovery") |
        .metadata.name] | .[]
    ')"
    backup_cronjobs="$(kubectl -n monitoring get cronjobs restic-nas-backup restic-b2-backup \
      -o name --ignore-not-found)"
  fi
  [ -z "$active_jobs" ] || {
    printf '%s\n' "$active_jobs" >&2
    die "monitoring namespace has active Jobs"
  }

  [ -z "$backup_cronjobs" ] || {
    printf '%s\n' "$backup_cronjobs" >&2
    die "backup CronJobs already exist; remove the partial rebuild resources before full restore"
  }
  ok "no app controller/pod, active monitoring Job, or backup CronJob can touch /opt"
}

assert_recovery_permissions() {
  local verb resource namespace answer
  while read -r verb resource namespace; do
    if [ "$namespace" = cluster ]; then
      answer="$(kubectl auth can-i "$verb" "$resource")"
    else
      answer="$(kubectl auth can-i "$verb" "$resource" -n "$namespace")"
    fi
    [ "$answer" = yes ] \
      || die "current kubeconfig cannot $verb $resource in $namespace; switch explicitly to the admin context for recovery"
  done <<'EOF'
create namespaces cluster
patch namespaces cluster
create secrets monitoring
patch secrets monitoring
create jobs.batch monitoring
delete jobs.batch monitoring
create secrets media
patch secrets media
create jobs.batch media
delete jobs.batch media
EOF
  ok "current kubeconfig has the narrowly checked write permissions needed for offline recovery"
}

assert_resume_permissions() {
  local resource answer
  for resource in \
    kustomizations.kustomize.toolkit.fluxcd.io \
    gitrepositories.source.toolkit.fluxcd.io; do
    answer="$(kubectl auth can-i patch "$resource" -n flux-system)"
    [ "$answer" = yes ] \
      || die "current kubeconfig cannot patch $resource; switch explicitly to the admin context"
  done
  ok "current kubeconfig can reconcile Flux sources and Kustomizations"
}

delete_recovery_job() {
  local namespace="$1" job="$2" namespace_resource
  namespace_resource="$(kubectl get namespace "$namespace" -o name --ignore-not-found)"
  if [ -n "$namespace_resource" ]; then
    kubectl -n "$namespace" delete "job/$job" \
      --ignore-not-found=true --cascade=foreground --wait=true >/dev/null
  fi
}

ensure_namespace() {
  local namespace="$1"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_sops_secret() {
  local path="$1" namespace="$2"
  ensure_namespace "$namespace"
  SOPS_AGE_KEY_FILE="$REPO_ROOT/age.key" sops --decrypt "$REPO_ROOT/$path" \
    | kubectl apply -f - >/dev/null
  ok "applied encrypted recovery credential $(basename "$path") without a plaintext file"
}

apply_restic_recovery_secret() {
  require_recovery_source
  case "$RECOVERY_SOURCE" in
    nas) apply_sops_secret infrastructure/monitoring/restic-nas.sops.yaml monitoring ;;
    b2) apply_sops_secret infrastructure/monitoring/restic-b2.sops.yaml monitoring ;;
  esac
}

write_restic_env() {
  # Emit YAML fragments at the indentation expected below a container's env key.
  case "$RECOVERY_SOURCE" in
    nas)
      cat <<'YAML'
            - name: RESTIC_REPOSITORY
              value: /repo/nas/opt
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-nas
                  key: RESTIC_PASSWORD
YAML
      ;;
    b2)
      cat <<'YAML'
            - name: RESTIC_REPOSITORY
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: RESTIC_REPOSITORY
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: RESTIC_PASSWORD
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: restic-b2
                  key: AWS_SECRET_ACCESS_KEY
YAML
      ;;
  esac
  cat <<'YAML'
            - name: RESTIC_CACHE_DIR
              value: /tmp/restic-cache
YAML
}

write_restic_repository_volume() {
  [ "$RECOVERY_SOURCE" = nas ] || return 0
  cat <<'YAML'
            - name: repository
              mountPath: /repo/nas
              readOnly: true
YAML
}

write_restic_repository_host_volume() {
  [ "$RECOVERY_SOURCE" = nas ] || return 0
  cat <<'YAML'
        - name: repository
          hostPath:
            path: /mnt/backups
            type: Directory
YAML
}

wait_for_recovery_job() {
  local namespace="$1" job="$2" timeout_value="$3"
  if ! kubectl -n "$namespace" wait "job/$job" --for=condition=Complete --timeout="$timeout_value"; then
    kubectl -n "$namespace" describe "job/$job" || true
    kubectl -n "$namespace" logs "job/$job" --all-containers=true || true
    die "recovery Job $namespace/$job failed"
  fi
  kubectl -n "$namespace" logs "job/$job" --all-containers=true
  ok "recovery Job $namespace/$job completed"
}

state_value() {
  local key="$1"
  sudo test -f "$RECOVERY_STATE_FILE" || return 0
  sudo awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' \
    "$RECOVERY_STATE_FILE"
}

set_state_value() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[a-z_]+$ ]] || die "invalid recovery state key: $key"
  [[ "$value" =~ ^[A-Za-z0-9._/:+-]+$ ]] || die "invalid recovery state value for $key"
  tmp="$(mktemp)"
  if sudo test -f "$RECOVERY_STATE_FILE"; then
    cat "$RECOVERY_STATE_FILE" >"$tmp"
  fi
  awk -F= -v key="$key" '$1 != key' "$tmp" >"$tmp.next"
  printf '%s=%s\n' "$key" "$value" >>"$tmp.next"
  sudo install -d -o root -g root -m 0755 "$RECOVERY_STATE_DIR"
  sudo install -o root -g root -m 0644 "$tmp.next" "$RECOVERY_STATE_FILE"
  rm -f "$tmp" "$tmp.next"
}

assert_state_matches_selection() {
  local selected_source selected_snapshot selected_stage expected_stage
  selected_source="$(state_value source)"
  selected_snapshot="$(state_value snapshot)"
  selected_stage="$(state_value stage)"
  expected_stage="$(recovery_stage_dir)"
  [ -z "$selected_source" ] || [ "$selected_source" = "$RECOVERY_SOURCE" ] \
    || die "recovery state source is $selected_source, requested $RECOVERY_SOURCE"
  [ -z "$selected_snapshot" ] || [ "$selected_snapshot" = "$RECOVERY_SNAPSHOT" ] \
    || die "recovery state snapshot is $selected_snapshot, requested $RECOVERY_SNAPSHOT"
  [ -z "$selected_stage" ] || [ "$selected_stage" = "$expected_stage" ] \
    || die "recovery state stage is $selected_stage, requested $expected_stage"
}

record_recovery_selection() {
  set_state_value source "$RECOVERY_SOURCE"
  set_state_value snapshot "$RECOVERY_SNAPSHOT"
  set_state_value stage "$(recovery_stage_dir)"
}

assert_recovery_preconditions() {
  require_not_root
  require_sudo
  require_tools git jq kubectl mountpoint findmnt readlink sops stat timeout yq
  require_recovery_source
  assert_recovery_repo_files
  [ "$(hostname -s)" = minis ] || die "run this recovery procedure on minis"
  assert_git_guard apps true
  assert_git_guard monitoring true
  assert_live_guard apps true
  assert_live_guard monitoring true
  assert_recovery_permissions
  assert_opt_mount
  assert_no_stateful_workloads
}

assert_resume_git_posture() {
  local apps_expected="$1" monitoring_expected="$2"
  require_not_root
  require_tools flux git jq kubectl yq
  [ "$(hostname -s)" = minis ] || die "run this recovery procedure on minis"
  assert_git_guard apps "$apps_expected"
  assert_git_guard monitoring "$monitoring_expected"
  assert_git_clean_and_synced
  assert_resume_permissions
}
