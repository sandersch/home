#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monitoring="$repo_root/infrastructure/monitoring/contracts"
recovery="$repo_root/runbooks/disaster-recovery/contracts"

cmp -s "$monitoring/vault-v1.json" "$recovery/vault-v1.json"
cmp -s "$monitoring/vault-v1.excludes" "$recovery/vault-v1.excludes"

expected_exclusion_hash="$(jq -er '.exclusion_sha256' "$monitoring/vault-v1.json")"
actual_exclusion_hash="$(sha256sum "$monitoring/vault-v1.excludes" | awk '{print $1}')"
[ "$actual_exclusion_hash" = "$expected_exclusion_hash" ]

jq -e '
  .contract == "vault-v1" and
  .source_roots == ["/data/vault"] and
  .sentinel == "/data/vault/.vault-sentinel" and
  .shrink_baseline_samples == 7 and
  .maximum_shrink_percent == 20 and
  .required_content == [
    {
      "path": "/data/vault/credentials/strongbox/ccs.kdbx",
      "kind": "kdbx",
      "minimum_files": 1,
      "minimum_bytes": 102400
    },
    {
      "path": "/data/vault/documents/ryze",
      "kind": "directory",
      "minimum_files": 400,
      "minimum_bytes": 209715200
    }
  ]
' "$monitoring/vault-v1.json" >/dev/null

mapfile -t exclusions <"$monitoring/vault-v1.excludes"
[ "${#exclusions[@]}" -eq 4 ]
[ "${exclusions[0]}" = /data/vault/.backup-credentials ]
[ "${exclusions[1]}" = /data/vault/.mail-credentials ]
[ "${exclusions[2]}" = /data/vault/inbox ]
[ "${exclusions[3]}" = /data/vault/.restore-tests ]

contract_hash="$(sha256sum "$monitoring/vault-v1.json" | awk '{print $1}')"
manifest="$(jq -n \
  --arg contract_hash "$contract_hash" \
  --arg exclusion_hash "$actual_exclusion_hash" '
  {
    contract:"vault-v1",
    contract_sha256:$contract_hash,
    exclusion_sha256:$exclusion_hash,
    measurements:[
      {path:"/data/vault/credentials/strongbox/ccs.kdbx",kind:"kdbx",files:1,bytes:138055},
      {path:"/data/vault/documents/ryze",kind:"directory",files:538,bytes:296757693}
    ]
  }
')"
manifest_filter='
  . as $manifest |
  $manifest.contract == $released[0].contract and
  $manifest.contract_sha256 == $contract_hash and
  $manifest.exclusion_sha256 == $exclusion_hash and
  ([$manifest.measurements[].path] == [$released[0].required_content[].path]) and
  all($released[0].required_content[];
    . as $required |
    any($manifest.measurements[];
      .path == $required.path and
      .kind == $required.kind and
      .files >= $required.minimum_files and
      .bytes >= $required.minimum_bytes))
'
jq -e \
  --arg contract_hash "$contract_hash" \
  --arg exclusion_hash "$actual_exclusion_hash" \
  --slurpfile released "$monitoring/vault-v1.json" \
  "$manifest_filter" <<<"$manifest" >/dev/null
if jq -e \
  --arg contract_hash "$contract_hash" \
  --arg exclusion_hash "$actual_exclusion_hash" \
  --slurpfile released "$monitoring/vault-v1.json" \
  "$manifest_filter" <<<"$(jq '.measurements[1].files = 1' <<<"$manifest")" >/dev/null; then
  echo "vault manifest floors accepted an invalid fixture" >&2
  exit 1
fi

base="${PR_BASE_SHA:-HEAD^}"
if git -C "$repo_root" rev-parse --verify "$base^{commit}" >/dev/null 2>&1; then
  while IFS=$'\t' read -r status path _; do
    case "$status" in
      M*|D*|R*)
        case "$path" in
          infrastructure/monitoring/contracts/vault-v[0-9]*.json|\
          runbooks/disaster-recovery/contracts/vault-v[0-9]*.json)
            echo "released vault contracts are immutable; add a new version instead of changing $path" >&2
            exit 1
            ;;
        esac
        ;;
    esac
  done < <(git -C "$repo_root" diff --name-status "$base" -- \
    infrastructure/monitoring/contracts \
    runbooks/disaster-recovery/contracts)
fi

echo "vault contract tests passed"
