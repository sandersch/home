#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# The attended runbooks require the Python jq-wrapper yq, while GitHub-hosted
# runners provide Mike Farah's Go yq. Keep this test portable across both
# command-line interfaces while exercising the same YAML transformation.
if yq eval --help 2>&1 | grep -q 'prettyPrint'; then
  yq_yaml() { yq eval -P "$@"; }
  yq_edit() { yq eval -P -i "$@"; }
else
  yq_yaml() { yq -y "$@"; }
  yq_edit() { yq -y -i "$@"; }
fi

files=(
  infrastructure/monitoring/restic-mount-guard.yaml
  infrastructure/monitoring/restic-vault-config.yaml
  infrastructure/monitoring/restic-verify-config.yaml
)

for relative in "${files[@]}"; do
  file="$repo_root/$relative"
  while IFS= read -r key; do
    script="$tmpdir/$(basename "$file")-$key"
    yq -r ".data[\"$key\"]" "$file" >"$script"
    bash -n "$script"
    shellcheck --severity=warning "$script"
  done < <(yq -r '.data | keys | .[] | select(test("\\.sh$"))' "$file")
done

host_scripts=(
  host/minis/usr/local/sbin/backups-mountpoint-guard
  host/minis/usr/local/sbin/vault-ingest-promote
  host/minis/usr/local/sbin/vault-mountpoint-guard
  host/minis/usr/local/sbin/vault-unlock
  host/ryze/usr/local/bin/vault-ingest
)
for relative in "${host_scripts[@]}"; do
  bash -n "$repo_root/$relative"
  shellcheck --severity=warning "$repo_root/$relative"
done

ingest_sshd="$repo_root/host/minis/etc/ssh/sshd_config_vault_ingest"
grep -qx 'UsePAM yes' "$ingest_sshd" \
  || { echo "vault ingestion must use PAM account checks for its locked system identity" >&2; exit 1; }
grep -qx 'PasswordAuthentication no' "$ingest_sshd"
grep -qx 'KbdInteractiveAuthentication no' "$ingest_sshd"

# A file hostPath is already the mount source; subPath would resolve a child
# beneath that file and fail before the container can execute any guard.
for cronjob in restic-vault-cronjob.yaml restic-verify-cronjob.yaml; do
  manifest="$repo_root/infrastructure/monitoring/$cronjob"
  file_volumes="$(yq -r '
    .spec.jobTemplate.spec.template.spec.volumes[]
    | select(.hostPath.type == "File" or .hostPath.type == "FileOrCreate")
    | .name
  ' "$manifest")"
  while IFS=$'\t' read -r mount_name sub_path sub_path_expr; do
    [ -n "$mount_name" ] || continue
    if grep -Fxq -- "$mount_name" <<<"$file_volumes" \
      && { [ -n "$sub_path" ] || [ -n "$sub_path_expr" ]; }; then
      echo "$cronjob mounts a child beneath a file hostPath" >&2
      exit 1
    fi
  done < <(yq -r '
    .spec.jobTemplate.spec.template.spec.containers[].volumeMounts[]
    | [.name, (.subPath // ""), (.subPathExpr // "")]
    | @tsv
  ' "$manifest")
done

# Exercise the actual attended Job transformation, including its ownership
# privilege, without creating anything in the cluster.
restore_filter="$tmpdir/restore-job.jq"
awk '
  $0 == "yq -y -i \047" { printing = 1; next }
  printing && index($0, "\047 ") == 1 { exit }
  printing { print }
' "$repo_root/runbooks/backups/06-validate-vault-restore.sh" >"$restore_filter"
[ -s "$restore_filter" ]
yq_yaml '{"spec": .spec.jobTemplate.spec}' \
  "$repo_root/infrastructure/monitoring/restic-vault-cronjob.yaml" \
  >"$tmpdir/restore-job.yaml"
VAULT_SNAPSHOT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  yq_edit -f "$restore_filter" "$tmpdir/restore-job.yaml"
yq -e '
  .spec.template.spec.containers[0] |
  (.securityContext.capabilities.drop == ["ALL"]) and
  (.securityContext.capabilities.add | sort == ["CHOWN", "DAC_OVERRIDE"]) and
  (.command[-1] | endswith("exec /scripts/validate-vault-restore.sh")) and
  any(.volumeMounts[]; .name == "vault" and .readOnly == false)
' "$tmpdir/restore-job.yaml" >/dev/null

promoter="$repo_root/host/minis/usr/local/sbin/vault-ingest-promote"
grep -q 'mv -- "$archive" "$claimed_archive"' "$promoter" \
  && grep -q 'sha256sum "$frozen_archive"' "$promoter" \
  && grep -q 'tar -tf "$frozen_archive"' "$promoter" \
  && grep -q 'tar -xf "$frozen_archive"' "$promoter" \
  || { echo "document promotion must validate and extract a root-only frozen archive" >&2; exit 1; }

promoter_unit="$repo_root/host/minis/etc/systemd/system/vault-ingest-promote.service"
grep -qx 'ConditionPathIsMountPoint=/mnt/vault' "$promoter_unit" \
  || { echo "vault promoter must require the mounted vault path" >&2; exit 1; }
! grep -qx 'Requires=mnt-vault.mount' "$promoter_unit" \
  || { echo "vault promoter must not depend on a generated noauto mount unit" >&2; exit 1; }

exclusion_filter="$tmpdir/detect-vault-exclusions.jq"
yq -r '.data."detect-vault-exclusions.jq"' \
  "$repo_root/infrastructure/monitoring/restic-vault-config.yaml" >"$exclusion_filter"

leaked_listing="$tmpdir/leaked-listing.jsonl"
cat >"$leaked_listing" <<'EOF'
{"message_type":"node","path":"/data/vault/documents/ryze/before.txt"}
{"message_type":"node","path":"/data/vault/.backup-credentials/nas-password"}
{"message_type":"node","path":"/data/vault/documents/ryze/after.txt"}
EOF
jq -e -f "$exclusion_filter" "$leaked_listing" >/dev/null \
  || { echo "credential exclusion filter missed a leak followed by an ordinary node" >&2; exit 1; }

clean_listing="$tmpdir/clean-listing.jsonl"
cat >"$clean_listing" <<'EOF'
{"message_type":"node","path":"/data/vault/documents/ryze/file.txt"}
{"message_type":"node","path":"/data/vault/.backup-credentials-old/allowed.txt"}
{"message_type":"summary","path":"/data/vault/.backup-credentials/nas-password"}
EOF
if jq -e -f "$exclusion_filter" "$clean_listing" >/dev/null; then
  echo "credential exclusion filter reported a clean listing" >&2
  exit 1
fi

yq -e '
  .spec.jobTemplate.spec.template.spec.containers[]
  | select(.name == "restic")
  | .volumeMounts[]
  | select(.name == "backups")
  | (.readOnly // false) == false
' "$repo_root/infrastructure/monitoring/restic-verify-cronjob.yaml" >/dev/null \
  || { echo "restic-verify must mount the NAS repositories read-write for repository locks" >&2; exit 1; }

repository_check_expr="$(yq -r '
  .spec.groups[].rules[]
  | select(.alert == "ResticRepositoryCheckOverdue")
  | .expr
' "$repo_root/infrastructure/monitoring/configs/alert-rules.yaml")"
for selector in \
  'dataset="appstate",destination=~"nas|b2"' \
  'dataset="appstate",destination="nas"' \
  'dataset="appstate",destination="b2"' \
  'dataset="vault",destination="nas"'; do
  [[ "$repository_check_expr" == *"$selector"* ]] \
    || { echo "repository-check alert is missing selector $selector" >&2; exit 1; }
done
[[ "$repository_check_expr" == *'node_filesystem_size_bytes{device="/dev/mapper/vault"'* ]] \
  || { echo "vault repository-check alert lost its mounted-vault gate" >&2; exit 1; }

echo "embedded backup scripts passed syntax and ShellCheck validation"
