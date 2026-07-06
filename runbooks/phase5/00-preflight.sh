#!/usr/bin/env bash
# Phase 5 preflight - verify backup manifests and local prerequisites.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kustomize

step "Verify Phase 5 backup tree"
assert_phase5_backup_tree

step "Verify local kustomize output"
assert_phase5_kustomize_builds

if [ -f "$PHASE5_RESTIC_SECRET" ]; then
  step "Verify Restic Secret manifest"
  assert_phase5_restic_secret_present
else
  warn "Restic Secret is not generated yet; run 02-encrypt-restic-secret.sh before reconciling monitoring"
fi

ok "Phase 5 backup preflight complete"
