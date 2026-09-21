#!/bin/sh
set -eu
: "${RESTORE_SNAPSHOT:?full snapshot ID is required}"
case "$RESTORE_SNAPSHOT" in *[!0-9a-f]*|'') echo "invalid snapshot ID" >&2; exit 1 ;; esac
[ "${#RESTORE_SNAPSHOT}" -eq 64 ] || { echo "snapshot ID must be 64 hex characters" >&2; exit 1; }
: "${RESTIC_REPOSITORY:?repository is required}"
: "${RESTIC_PASSWORD_FILE:?password file is required}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/work/restic-cache}"
mkdir -p "$RESTIC_CACHE_DIR"
stage="/repo/nas/.control/vault/frigate-restore-$RESTORE_SNAPSHOT"
[ ! -e "$stage" ] || { echo "restore staging path already exists: $stage" >&2; exit 1; }
umask 077
mkdir -p "$stage"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT HUP INT TERM
restic snapshots "$RESTORE_SNAPSHOT" --json | jq -e --arg id "$RESTORE_SNAPSHOT" 'length == 1 and .[0].id == $id' >/dev/null
restic dump "$RESTORE_SNAPSHOT" /data/vault/frigate-exports/.ingestion-inventory.json >"$stage/inventory.json"
jq -e '.schema == 1 and (.files | type == "array")' "$stage/inventory.json" >/dev/null
restic restore "$RESTORE_SNAPSHOT" --target "$stage/tree" --include /data/vault/frigate-exports
python3 /usr/local/bin/verify-frigate-restore "$stage/tree/data/vault/frigate-exports"
echo "RESTORE_SNAPSHOT=$RESTORE_SNAPSHOT"
echo "RESTORE_INVENTORY_SHA256=$(sha256sum "$stage/inventory.json" | awk '{print $1}')"
