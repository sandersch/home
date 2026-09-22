#!/bin/sh
# Run only inside the disposable image-test container.
set -eu
export RESTIC_REPOSITORY=/tmp/restore-test-repository
export RESTIC_PASSWORD_FILE=/tmp/restore-test-password
export RESTIC_CACHE_DIR=/tmp/restore-test-cache
printf '%s\n' fixture-password >"$RESTIC_PASSWORD_FILE"
mkdir -p /tmp/exports /data/vault/frigate-exports
ffmpeg -v error -f lavfi -i color=c=black:s=32x32:d=1 -c:v mpeg4 /tmp/exports/clip.mp4
/usr/local/bin/frigate-ingest /tmp/exports /data/vault/frigate-exports
restic init
restic backup /data/vault/frigate-exports
RESTORE_SNAPSHOT="$(restic snapshots --json | jq -r '.[0].id')"
export RESTORE_SNAPSHOT
# Local Job entrypoint.
/bin/sh -c /usr/local/bin/validate-frigate-restore
# B2 Job shell and environment handoff, using a disposable local repository
# so the image test needs no network or production credentials.
printf 'VAULT_B2_REPOSITORY=%s\n' "$RESTIC_REPOSITORY" >/tmp/vault-b2.conf
/bin/bash -c 'source /tmp/vault-b2.conf; export RESTIC_REPOSITORY="$VAULT_B2_REPOSITORY"; exec /usr/local/bin/validate-frigate-restore'
[ ! -e "/repo/nas/.control/vault/frigate-restore-$RESTORE_SNAPSHOT" ]
