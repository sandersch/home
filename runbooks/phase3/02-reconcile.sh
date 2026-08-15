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
if ! flux reconcile kustomization infra-controllers --with-source; then
  warn "infra-controllers did not become Ready; forcing Tailscale HelmRelease once in case it is in a terminal failed state"
  flux reconcile helmrelease tailscale-operator -n flux-system --with-source --reset --force || true
  flux reconcile kustomization infra-controllers --with-source
fi
kustomization_ready infra-controllers 600s
flux get helmreleases -A

step "Reconcile infra configs"
flux reconcile kustomization infra-configs --with-source
kustomization_ready infra-configs 600s

step "Verify or reconcile workload targets"
if kustomization_is_suspended apps; then
  require_kustomization_suspended apps
  require_kustomization_suspended monitoring
  ok "leaving stateful workloads and backup schedules unreconciled until restore"
else
  flux reconcile kustomization apps --with-source
  kustomization_ready apps 180s
fi

ok "Phase 3 reconcile complete"
