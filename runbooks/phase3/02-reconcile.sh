#!/usr/bin/env bash
# Phase 3 reconcile - push Flux through controllers and dependent config.
# shellcheck source=runbooks/phase3/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl kustomize
require_flux_cli

step "Preflight manifests and secrets"
assert_phase3_tree
assert_kustomize_builds
assert_secret_manifests_present

step "Reconcile infra controllers"
flux reconcile kustomization infra-controllers --with-source
kustomization_ready infra-controllers 600s
flux get helmreleases -A

step "Reconcile infra configs"
flux reconcile kustomization infra-configs --with-source
kustomization_ready infra-configs 600s

step "Reconcile empty apps target"
flux reconcile kustomization apps --with-source
kustomization_ready apps 180s

ok "Phase 3 reconcile complete"
