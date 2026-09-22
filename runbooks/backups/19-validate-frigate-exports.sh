#!/usr/bin/env bash
# Restore and verify Frigate archives from exact local and B2 vault snapshots.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root
require_sudo
require_tools jq kubectl yq
require_backup_yq
[ "$(hostname -s)" = minis ] || die "run this attended restore on minis"
[ -t 0 ] || die "Frigate restore verification requires an attended TTY"
: "${LOCAL_SNAPSHOT:?set the exact local vault snapshot ID}"
: "${B2_SNAPSHOT:?set the exact B2 vault snapshot ID}"
: "${FRIGATE_INGEST_IMAGE:?set the published name@sha256 digest from the image release workflow}"
for snapshot in "$LOCAL_SNAPSHOT" "$B2_SNAPSHOT"; do
  [[ "$snapshot" =~ ^[0-9a-f]{64}$ ]] || die "snapshot IDs must be full lowercase 64-character IDs"
done
[[ "$FRIGATE_INGEST_IMAGE" =~ ^ghcr\.io/sandersch/frigate-ingest:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] \
  || die "FRIGATE_INGEST_IMAGE must be an immutable published release reference"
sudo /usr/local/sbin/vault-unlock
sudo grep -qxF 'vault-contract-version=3' /mnt/vault/.vault-sentinel \
  || die "vault must be at the validated v3 contract"

run_validation() {
  local kind="$1" snapshot="$2" base job manifest command
  base=restic-vault-backup
  if [ "$kind" = b2 ]; then base=restic-vault-copy; fi
  job="restic-frigate-${kind}-${snapshot:0:12}"
  kubectl -n monitoring get job "$job" >/dev/null 2>&1 \
    && die "job/$job already exists; inspect its state before retrying"
  manifest="$(mktemp)"
  trap 'rm -f "$manifest"' RETURN
  kubectl -n monitoring create job "$job" --from="cronjob/$base" --dry-run=client -o yaml >"$manifest"
  # Restore ownership and metadata for UID/GID 2207; scope these grants to restore Jobs.
  yq -y -i '.spec.template.spec.containers[0].securityContext.capabilities.add += ["CHOWN", "FOWNER"]' "$manifest"
  if [ "$kind" = local ]; then
    command='/usr/local/bin/validate-frigate-restore'
    SNAPSHOT="$snapshot" IMAGE="$FRIGATE_INGEST_IMAGE" yq -y -i '
      .spec.template.spec.initContainers = [] |
      .spec.template.spec.volumes |= map(select(.name != "ingestion-script" and .name != "frigate-exports")) |
      .spec.template.spec.containers[0].image = env.IMAGE |
      .spec.template.spec.containers[0].command = ["/bin/sh", "-c", "/usr/local/bin/validate-frigate-restore"] |
      .spec.template.spec.containers[0].env += [{"name":"RESTORE_SNAPSHOT","value":env.SNAPSHOT}]
    ' "$manifest"
  else
    command='source /etc/homelab/vault-b2.conf; export RESTIC_REPOSITORY="$VAULT_B2_REPOSITORY"; export AWS_ACCESS_KEY_ID="$(cat /data/vault/.backup-credentials/b2-key-id)"; export AWS_SECRET_ACCESS_KEY="$(cat /data/vault/.backup-credentials/b2-application-key)"; export RESTIC_PASSWORD_FILE=/data/vault/.backup-credentials/b2-password; exec /usr/local/bin/validate-frigate-restore'
    SNAPSHOT="$snapshot" IMAGE="$FRIGATE_INGEST_IMAGE" SCRIPT="$command" yq -y -i '
      .spec.template.spec.containers[0].image = env.IMAGE |
      .spec.template.spec.containers[0].command = ["/bin/bash", "-c", env.SCRIPT] |
      .spec.template.spec.containers[0].env += [{"name":"RESTORE_SNAPSHOT","value":env.SNAPSHOT}]
    ' "$manifest"
  fi
  kubectl apply -f "$manifest" >/dev/null
  kubectl -n monitoring wait --for=condition=complete "job/$job" --timeout=86400s \
    || { kubectl -n monitoring logs "job/$job" --all-containers=true || true; die "$job failed"; }
  kubectl -n monitoring logs "job/$job" --all-containers=true
}

cat <<EOF
Local snapshot: $LOCAL_SNAPSHOT
B2 snapshot:    $B2_SNAPSHOT
Image:          $FRIGATE_INGEST_IMAGE

Each restore compares the restored tree with the snapshot's own archived inventory,
checks every file's size and SHA-256, and decodes every image/video. Restore staging is
removed on completion. Interrupted jobs may leave only the exact .control/vault staging
directory named in the failure log; inspect it before an attended cleanup.
EOF
read -r -p 'Type VALIDATE-FRIGATE-RESTORES to continue: ' confirmation
[ "$confirmation" = VALIDATE-FRIGATE-RESTORES ] || die "confirmation did not match"
run_validation local "$LOCAL_SNAPSHOT"
run_validation b2 "$B2_SNAPSHOT"
ok "exact local and B2 Frigate restore validations passed"
