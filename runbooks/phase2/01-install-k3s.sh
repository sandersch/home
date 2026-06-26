#!/usr/bin/env bash
# Phase 2.1 - install k3s with the cluster shape expected by the build plan.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools curl systemctl

kubeconfig_dest="$HOME/.kube/config"

setup_user_kubeconfig() {
  local kube_dir
  kube_dir="$(dirname "$kubeconfig_dest")"
  [ -f /etc/rancher/k3s/k3s.yaml ] || die "/etc/rancher/k3s/k3s.yaml is missing"
  install -d -m 0700 "$kube_dir"
  sudo install -m 0600 -o "$(id -u)" -g "$(id -g)" \
    /etc/rancher/k3s/k3s.yaml "$kubeconfig_dest"
  ok "installed $kubeconfig_dest for $(id -un) (0600)"
}

step "Verify host prerequisites"
assert_hostname_minis
assert_no_swap

if systemctl is-active --quiet k3s; then
  warn "k3s is already active; skipping installer and validating the node"
else
  cat <<'EOF'
k3s will be installed with:
  --disable traefik --disable servicelb --node-name minis

The node name is load-bearing because app PV nodeAffinity pins to the kubelet's
kubernetes.io/hostname label.
EOF
  confirm "Install k3s now?" || die "aborted"
  curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik --disable servicelb \
    --node-name minis
fi

step "Validate k3s"
systemctl is-active --quiet k3s || die "k3s service is not active"
setup_user_kubeconfig
assert_kubectl_ready
