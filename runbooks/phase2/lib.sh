#!/usr/bin/env bash
# Phase 2 helpers.
#
# Phase 2 installs k3s, creates the SOPS age secret, and bootstraps Flux. Keep
# these checks focused on bootstrap safety; Phase 3 owns all normal cluster state.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

age_key_file() {
  printf '%s/age.key\n' "$REPO_ROOT"
}

sops_config_file() {
  printf '%s/.sops.yaml\n' "$REPO_ROOT"
}

assert_hostname_minis() {
  local hn
  hn="$(hostname)"
  [ "$hn" = "minis" ] || die "hostname is '$hn', expected 'minis' before k3s install"
  ok "hostname is minis"
}

assert_no_swap() {
  if [ -n "$(swapon --show)" ]; then
    swapon --show
    die "swap is active; kubelet requires swap off"
  fi
  ok "swap is off"
}

assert_phase2_cluster_skeleton() {
  local f missing=0
  for f in \
    clusters/minis/kustomization.yaml \
    clusters/minis/infra-controllers.yaml \
    clusters/minis/infra-configs.yaml \
    clusters/minis/apps.yaml; do
    if [ -f "$REPO_ROOT/$f" ]; then
      ok "$f present"
    else
      warn "$f missing"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "Flux cluster skeleton is incomplete"
}

assert_flux_system_absent_or_owned() {
  if [ -e "$REPO_ROOT/clusters/minis/flux-system" ]; then
    warn "clusters/minis/flux-system already exists"
    [ -f "$REPO_ROOT/clusters/minis/flux-system/gotk-components.yaml" ] \
      || die "existing flux-system dir does not look like Flux bootstrap output"
  else
    ok "clusters/minis/flux-system is absent; flux bootstrap will create it"
  fi
}

assert_git_clean_or_warn() {
  if [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]; then
    ok "git worktree has no tracked or untracked changes"
  else
    warn "git worktree has changes; review before flux bootstrap commits"
    git -C "$REPO_ROOT" status --short --untracked-files=all
  fi
}

assert_git_clean_for_bootstrap() {
  local status upstream counts ahead behind

  status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
  if [ -n "$status" ]; then
    warn "git worktree must be clean before flux bootstrap; ignored files such as age.key are allowed"
    printf '%s\n' "$status" >&2
    die "commit, stash, or remove these changes before bootstrap"
  fi

  upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$upstream" ] || die "current branch has no upstream; configure tracking before bootstrap"

  counts="$(git -C "$REPO_ROOT" rev-list --left-right --count HEAD..."$upstream")"
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  [ "$ahead" = "0" ] || die "current branch has $ahead unpushed commit(s) relative to $upstream"
  [ "$behind" = "0" ] || die "current branch is $behind commit(s) behind $upstream; pull before bootstrap"
  ok "git branch is clean and up to date with $upstream"
}

assert_kubectl_ready() {
  require_tools kubectl
  local deadline=$(( SECONDS + 60 )) ready=""
  # A freshly installed k3s returns from the installer before the API server
  # serves and before kubelet registers the node Ready (flannel/CNI lag), so
  # poll for up to ~60s rather than failing on the first miss.
  while [ "$SECONDS" -lt "$deadline" ]; do
    if kubectl get nodes >/dev/null 2>&1; then
      ready="$(kubectl get node minis \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      [ "$ready" = "True" ] && break
    fi
    sleep 3
  done
  kubectl get nodes >/dev/null || die "kubernetes API is not reachable"
  kubectl get nodes
  [ "$ready" = "True" ] || die "node minis did not become Ready within 60s"
  ok "kubernetes node minis is Ready"
}

age_public_key_from_file() {
  local key_file="${1:-$(age_key_file)}"
  [ -f "$key_file" ] || die "age key file missing: $key_file"
  age-keygen -y "$key_file"
}

assert_flux_system_reconciled() {
  require_tools kubectl
  local deadline=$(( SECONDS + 120 )) status=""
  # Right after bootstrap the flux-system Kustomization may take a few seconds to
  # report Ready=True, so poll rather than failing on the first miss.
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(kubectl -n flux-system get kustomization flux-system \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$status" = "True" ] && break
    sleep 3
  done
  [ "$status" = "True" ] \
    || die "flux-system Kustomization did not reach Ready=True within 120s"
  ok "flux-system Kustomization is Reconciled (Ready=True)"
}
