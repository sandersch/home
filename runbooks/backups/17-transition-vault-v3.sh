#!/usr/bin/env bash
# Attended vault-v2 -> vault-v3 transition. This runbook only prepares and verifies
# the cutover; activation and semantic acceptance remain explicit operator actions.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_not_root; require_sudo
[ "$(hostname -s)" = minis ] || die "run on minis"
require_tools kubectl flux
step "Verify v2 is healthy before transition"
sudo test -f /etc/homelab/vault.conf
sudo grep -qxF 'export VAULT_CONTRACT_VERSION=2' /etc/homelab/vault.conf
sudo test -d /mnt/vault/documents/m5c
step "Release immutable v3 contracts from the promoted M5c seed"
sudo python3 "$REPO_ROOT/runbooks/backups/workstation-release-vault-v3.py"
step "Verify both copies and the published ConfigMap"
cmp -s "$REPO_ROOT/infrastructure/monitoring/contracts/vault-v3.json" \
  "$REPO_ROOT/runbooks/disaster-recovery/contracts/vault-v3.json"
kubectl -n monitoring get configmap restic-vault-contract -o jsonpath='{.data.vault-v3\.json}' | jq -e '.contract == "vault-v3"'
cat <<'EOF'
Contracts are published while v2 remains active. Follow the attended cutover:
suspend monitoring Flux and the four vault CronJobs, drain running Jobs, pause
promotion, install matching host scripts/configuration, atomically replace the
sentinel with vault-contract-version=3, then reconcile. Create one v3 candidate,
run check --read-data and full NAS/B2 restores, manually inspect KDBX, both
Documents trees, and a photo, and accept the exact candidate with
HOLD_ACTION=accept, HOLD_OPERATOR, and HOLD_REASON. Resume schedules only after
the recovery gates and record evidence in evidence/vault-v3-transition-*.json.
EOF
