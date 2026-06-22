#!/usr/bin/env bash
# Phase 0 preflight — sanity-check the host before running any step.
# Read-only: changes nothing, just confirms assumptions the later scripts rely on.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Phase 0 preflight checks"

require_not_root
require_sudo
require_host_etc
ok "running as $(id -un); sudo works; host config found at $HOST_ETC"

# OS — the plan targets Ubuntu 24.04 LTS.
if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    ok "OS is Ubuntu 24.04 LTS"
  else
    if [ "${PHASE0_ALLOW_UNSUPPORTED_OS:-}" = "1" ]; then
      warn "OS is ${PRETTY_NAME:-unknown}; continuing because PHASE0_ALLOW_UNSUPPORTED_OS=1"
    else
      die "OS is ${PRETTY_NAME:-unknown}; the plan targets Ubuntu 24.04 LTS"
    fi
  fi
else
  die "cannot read /etc/os-release; refusing to run Phase 0 on an unidentified OS"
fi

# The two 2.5GbE NICs are identified by MAC (build-plan.md 0.2). Names may still be
# the kernel's enpXXsY at this stage — the lan0/cam0 rename lands after reboot.
assert_expected_nics

# Tools the steps assume exist out of the box.
for t in ip systemctl install cmp timeout findmnt readlink lvs vgs awk; do
  command -v "$t" >/dev/null || die "required tool missing: $t"
done
ok "base tooling present"

assert_phase0_storage_layout

step "Preflight complete"
cat <<'EOF'
Run the steps in order (or use run-all.sh):
  01-hostname-ssh.sh   set hostname=minis, harden SSH         (restarts sshd)
  02-networking.sh     static netplan + disable cloud-init net (rename on reboot)
  03-system-prep.sh    apt upgrade, packages, tz, swap, hw checks, rfkill
  04-nfs-mounts.sh     add the NAS NFS mount to fstab + mount
  05-ups-nut.sh        NUT/UPS configs + enable               (prompts for secret)
  06-coral-udev.sh     Coral udev rule + reload

Off-host (not scripted): 0.7 router DNS wildcard *.worm.run -> 10.137.20.10.
EOF
