#!/usr/bin/env bash
# Phase 5 preflight - verify backup manifests and local prerequisites.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kustomize yq

step "Verify Phase 5 backup tree"
assert_phase5_backup_tree

step "Verify local kustomize output"
assert_phase5_kustomize_builds

step "Verify NAS behavior and B2 safety invariants"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_phase5_backup_invariants "$tmpdir/monitoring.yaml"

if [ -f "$PHASE5_RESTIC_SECRET" ]; then
  step "Verify Restic Secret manifest"
  assert_phase5_restic_secret_present
else
  warn "Restic Secret is not generated yet; run 02-encrypt-restic-secret.sh before reconciling monitoring"
fi

if [ -f "$PHASE5_RESTIC_B2_SECRET" ]; then
  step "Verify Restic B2 Secret manifest"
  assert_phase5_restic_b2_secret_present
else
  warn "Restic B2 Secret is not generated yet; run 06-encrypt-restic-b2-secret.sh after provisioning B2"
fi

ok "Phase 5 backup preflight complete"
