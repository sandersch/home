#!/usr/bin/env bash
# Phase 2.1 - install k3s with the cluster shape expected by the build plan.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_tools curl systemctl

kubeconfig_dest="$HOME/.kube/config"
k3s_config_src="$HOST_ETC/rancher/k3s/config.yaml"
k3s_config_dest="/etc/rancher/k3s/config.yaml"
k3s_config_changed=0

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
  assert_k3s_version
fi

step "Install k3s server configuration"
require_host_etc
if [ ! -f "$k3s_config_dest" ] || ! sudo cmp -s "$k3s_config_src" "$k3s_config_dest"; then
  k3s_config_changed=1
fi
install_file rancher/k3s/config.yaml "$k3s_config_dest" root:root 600

if systemctl is-active --quiet k3s; then
  if [ "$k3s_config_changed" -eq 1 ]; then
    warn "k3s is already active and its server configuration changed"
    confirm "Restart k3s now to apply the new configuration?" \
      || die "configuration installed but not active; restart k3s before continuing"
    sudo systemctl restart k3s
    ok "restarted k3s"
  else
    warn "k3s is already active; skipping installer and validating the node"
  fi
else
  cat <<EOF
k3s $K3S_VERSION will be installed with:
  --disable traefik --disable servicelb --node-name minis
  kube-controller-manager terminated Pod GC threshold: 20

The node name is load-bearing because app PV nodeAffinity pins to the kubelet's
kubernetes.io/hostname label.
EOF
  confirm "Install k3s now?" || die "aborted"
  curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
    --disable traefik --disable servicelb \
    --node-name minis
fi

step "Validate k3s"
systemctl is-active --quiet k3s || die "k3s service is not active"
assert_k3s_version
setup_user_kubeconfig
assert_kubectl_ready
