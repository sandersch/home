#!/usr/bin/env bash
# Phase 3 preflight - validate local manifests and required tooling.
# shellcheck source=runbooks/phase3/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools git kustomize
require_flux_cli

step "Validate Phase 3 repo tree"
assert_phase3_tree

step "Validate kustomize output"
assert_kustomize_builds

step "Check encrypted secret manifests"
assert_secret_manifests_present

ok "Phase 3 preflight complete"
