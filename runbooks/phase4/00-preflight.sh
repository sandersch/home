#!/usr/bin/env bash
# Phase 4 preflight - verify the first app tree and local prerequisites.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kustomize

step "Verify Phase 4 download stack tree"
assert_phase4_download_stack_tree

step "Verify Phase 4 Plex tree"
assert_phase4_plex_tree

step "Verify Phase 4 RomM tree"
assert_phase4_romm_tree

step "Verify local kustomize output"
kustomize build "$REPO_ROOT/apps" >/dev/null
ok "kustomize build apps"

step "Verify Gluetun Secret manifest"
assert_phase4_secret_present

step "Verify RomM Secret manifest"
assert_phase4_romm_secret_present

ok "Phase 4 preflight complete"
