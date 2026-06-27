#!/usr/bin/env bash
# Phase 3 helpers.
#
# Phase 3 is the first normal Flux-managed cluster infrastructure phase. These
# helpers assume k3s and Flux bootstrap are already complete.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

require_flux_cli() {
  if command -v flux >/dev/null; then
    ok "flux CLI present"
    return 0
  fi
  die "flux CLI is required for Phase 3 validation"
}

assert_phase3_tree() {
  local f
  for f in \
    infrastructure/controllers/kustomization.yaml \
    infrastructure/configs/kustomization.yaml \
    infrastructure/configs/secrets/kustomization.yaml \
    apps/kustomization.yaml \
    clusters/minis/infra-controllers.yaml \
    clusters/minis/infra-configs.yaml \
    clusters/minis/apps.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 3 file: $f"
  done
  ok "Phase 3 repo tree is present"
}

assert_kustomize_builds() {
  require_tools kustomize
  local target
  for target in \
    clusters/minis \
    infrastructure/controllers \
    infrastructure/configs \
    apps; do
    kustomize build "$REPO_ROOT/$target" >/dev/null
    ok "kustomize build $target"
  done
}

assert_secret_manifests_present() {
  local f missing=0
  for f in \
    infrastructure/configs/secrets/clouddns-dns01-solver.sops.yaml \
    infrastructure/controllers/tailscale/tailscale-operator-oauth.sops.yaml; do
    if [ -f "$REPO_ROOT/$f" ]; then
      ok "$f present"
    else
      warn "$f missing"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "run 01-encrypt-secrets.sh before reconciling Phase 3"
}

kustomization_ready() {
  local name="$1" timeout="${2:-300s}"
  kubectl -n flux-system wait "kustomization.kustomize.toolkit.fluxcd.io/$name" \
    --for=condition=Ready --timeout="$timeout"
  ok "Flux Kustomization $name is Ready"
}
