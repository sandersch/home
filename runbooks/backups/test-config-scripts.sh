#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

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

promoter="$repo_root/host/minis/usr/local/sbin/vault-ingest-promote"
grep -q 'mv -- "$archive" "$claimed_archive"' "$promoter" \
  && grep -q 'sha256sum "$frozen_archive"' "$promoter" \
  && grep -q 'tar -tf "$frozen_archive"' "$promoter" \
  && grep -q 'tar -xf "$frozen_archive"' "$promoter" \
  || { echo "document promotion must validate and extract a root-only frozen archive" >&2; exit 1; }

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
