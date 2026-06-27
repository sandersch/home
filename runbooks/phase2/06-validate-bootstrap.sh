#!/usr/bin/env bash
# Phase 2 validation - confirm k3s and Flux bootstrap are usable.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl
require_flux_cli

step "Validate k3s node"
assert_kubectl_ready

step "Validate Flux bootstrap artifacts"
[ -f "$REPO_ROOT/clusters/minis/flux-system/gotk-components.yaml" ] \
  || die "clusters/minis/flux-system/gotk-components.yaml missing"
[ -f "$REPO_ROOT/clusters/minis/flux-system/gotk-sync.yaml" ] \
  || die "clusters/minis/flux-system/gotk-sync.yaml missing"
ok "Flux bootstrap manifests exist in clusters/minis/flux-system"

kubectl -n flux-system get secret sops-age >/dev/null \
  || die "flux-system/sops-age secret missing"
ok "flux-system/sops-age secret exists"

step "Flux status"
assert_flux_system_reconciled
flux get kustomizations
flux check

cat <<'EOF'

Phase 2 bootstrap validation complete.

Phase 3 is the first normal GitOps-managed cluster infrastructure phase. Do not
install controllers with imperative Helm commands.
EOF
