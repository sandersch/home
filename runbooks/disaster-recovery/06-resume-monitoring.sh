#!/usr/bin/env bash
# Reconcile backups/monitoring only after application recovery passed, then create
# fresh local and B2 snapshots and prove both are independently restorable.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_sudo
[ "$(state_value apps_validation)" = complete ] \
  || die "application recovery validation has not passed"
assert_resume_git_posture false false

step "Reconcile the committed monitoring resume"
flux reconcile kustomization flux-system --with-source
assert_live_guard apps false
assert_live_guard monitoring false
flux reconcile kustomization monitoring --with-source
kubectl -n flux-system wait kustomization/monitoring --for=condition=Ready --timeout=15m
ok "monitoring and backup schedules are reconciled"

step "Validate monitoring manifests and create fresh recovery points"
"$REPO_ROOT/runbooks/phase5/00-preflight.sh"
"$REPO_ROOT/runbooks/phase5/04-run-manual-backup.sh"
"$REPO_ROOT/runbooks/phase5/05-validate-restore.sh"
"$REPO_ROOT/runbooks/phase5/08-run-manual-b2-backup.sh"
"$REPO_ROOT/runbooks/phase5/09-validate-b2-restore.sh"
"$REPO_ROOT/runbooks/phase5/13-validate-nut-exporter.sh"

if [ "${RECOVERY_TEST_PUSHOVER:-0}" = 1 ]; then
  "$REPO_ROOT/runbooks/phase5/12-test-pushover.sh"
else
  warn "Pushover synthetic notification test skipped; set RECOVERY_TEST_PUSHOVER=1 to include it"
fi

cat <<'EOF'

Confirm externally that:
  - Dead Man's Snitch returned healthy after monitoring reconciled.
  - Grafana and Prometheus are reachable.
  - Pushover is receiving alerts, or its optional synthetic test passed.
EOF
confirm "External monitoring and notification recovery is healthy" \
  || die "disaster recovery remains incomplete"

set_state_value monitoring_validation complete
set_state_value recovery_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok "full disaster recovery completed with fresh local and B2 restore validation"

cat <<EOF

The staged restore remains at $(state_value stage). Keep it until the recovered system
has completed an observation window. Then run 07-close-recovery.sh to archive the
non-secret recovery record at $RECOVERY_STATE_FILE. Staging is never deleted by these
scripts.
EOF
