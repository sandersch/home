#!/usr/bin/env bash
# Phase 2.5 - bootstrap Flux against the private GitHub repo.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools git kubectl
require_flux_cli

step "Validate inputs"
[ -n "${GITHUB_TOKEN:-}" ] \
  || die "GITHUB_TOKEN is unset; flux bootstrap github needs a token with repo + admin:public_key scope. Export it before running (a mid-bootstrap failure can leave partial remote state)"
assert_kubectl_ready
sops_config="$(sops_config_file)"
[ -f "$sops_config" ] || die "missing $sops_config; run 04-sops-config.sh first"
kubectl -n flux-system get secret sops-age >/dev/null \
  || die "missing flux-system/sops-age; run 03-sops-age-secret.sh first"
assert_phase2_cluster_skeleton
assert_flux_system_absent_or_owned
step "Verify rebuild reconciliation guards"
assert_rebuild_targets_suspended_in_git
git -C "$REPO_ROOT" fetch --prune
assert_git_clean_for_bootstrap

cat <<'EOF'
This will run:
  flux bootstrap github \
    --owner=sandersch --repository=home \
    --branch=main --path=clusters/minis --personal --private

It may create/modify clusters/minis/flux-system, create a deploy key, commit Flux
manifests, and start reconciliation from the private GitHub repository. The committed
apps and monitoring backup Kustomizations are suspended so stateful workloads and
backup schedules cannot start before the restore gate.
EOF
confirm "Bootstrap Flux now?" || die "aborted"

flux bootstrap github \
  --owner=sandersch --repository=home \
  --branch=main --path=clusters/minis --personal --private

ok "flux bootstrap completed"

# bootstrap commits gotk-components.yaml/gotk-sync.yaml to the remote via a temp
# clone, not this working tree; fast-forward the local branch so the bootstrap
# commit is present locally (06-validate-bootstrap.sh checks for those files).
step "Sync local tree with the bootstrap commit"
git -C "$REPO_ROOT" pull --ff-only
ok "local branch fast-forwarded to the bootstrap commit"
