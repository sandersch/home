#!/usr/bin/env bash
# Test only the offline metadata gate; never invoke live recovery preconditions.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../disaster-recovery/lib.sh"
sudo() { "$@"; }
export RECOVERY_SOURCE=offline
export RECOVERY_SNAPSHOT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/data/opt" "$scratch/work/hot-dumps"
require_recovery_source
if (assert_offline_stage_metadata "$scratch") >/dev/null 2>&1; then
  echo 'missing metadata accepted' >&2
  exit 1
fi
jq -n --arg id "$RECOVERY_SNAPSHOT" \
  '[{id:$id,hostname:"minis",paths:["/data/opt","/work/hot-dumps"],tags:["opt","nas"]}]' \
  >"$scratch/offline-snapshot.json"
assert_offline_stage_metadata "$scratch"
if (RECOVERY_SNAPSHOT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; \
    assert_offline_stage_metadata "$scratch") >/dev/null 2>&1; then
  echo 'wrong snapshot accepted' >&2
  exit 1
fi
if (apply_restic_recovery_secret) >/dev/null 2>&1; then
  echo 'offline source allowed fetch credentials' >&2
  exit 1
fi
mv "$scratch/offline-snapshot.json" "$scratch/substituted.json"
ln -s substituted.json "$scratch/offline-snapshot.json"
if (assert_offline_stage_metadata "$scratch") >/dev/null 2>&1; then
  echo 'symlink metadata accepted' >&2
  exit 1
fi
printf '%s\n' 'PASS: offline recovery exact-ID metadata and no-fetch gates'
