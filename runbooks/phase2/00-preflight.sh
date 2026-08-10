#!/usr/bin/env bash
# Phase 2 preflight - read-only checks before k3s + Flux bootstrap.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Phase 2 preflight checks"

require_not_root
require_sudo
require_host_etc
require_tools curl git age age-keygen ip findmnt swapon hostname timeout awk

assert_hostname_minis
assert_no_swap
assert_phase0_network_settled
assert_direct_mount_layout /mnt/media /dev/mapper/hoardvg-medialv \
  0a94d86c-76a0-44b5-bc52-930d97ab155f

step "Verify repo bootstrap state"
assert_phase2_cluster_skeleton
assert_flux_system_absent_or_owned
assert_git_clean_or_warn

step "Check k3s and Flux tool posture"
if systemctl list-unit-files k3s.service >/dev/null 2>&1; then
  warn "k3s service already exists; 01-install-k3s.sh will validate rather than reinstall"
else
  ok "k3s service is not installed yet"
fi

if command -v kubectl >/dev/null; then
  warn "kubectl already present"
else
  ok "kubectl not present yet; k3s install will provide it on the host"
fi

if command -v flux >/dev/null; then
  ok "flux CLI present"
else
  warn "flux CLI missing; install it before 05-flux-bootstrap.sh"
  print_flux_cli_install_hint
fi

step "Preflight complete"
cat <<'EOF'
Run the Phase 2 steps in order:
  01-install-k3s.sh        install k3s without Traefik or servicelb
  02-age-keypair.sh        generate age.key and require password-manager backup
  03-sops-age-secret.sh    create/update flux-system/sops-age
  04-sops-config.sh        write repo .sops.yaml with the public key
  05-flux-bootstrap.sh     bootstrap Flux into clusters/minis/flux-system
  06-validate-bootstrap.sh validate k3s and Flux bootstrap state
EOF
