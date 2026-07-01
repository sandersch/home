#!/usr/bin/env bash
# Phase 0.6 — udev rule for the Coral USB accelerator.
#
# Gives the device stable, non-root permissions (MODE=0666, GROUP=plugdev) for
# Frigate's /dev/bus/usb hostPath. Frigate still runs privileged because the
# EdgeTPU delegate did not initialize in an unprivileged diagnostic pod. The Coral
# enumerates under two USB IDs — before and after its firmware loads — so the rule
# matches both.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc

step "Install Coral udev rule"
install_file udev/rules.d/99-coral.rules /etc/udev/rules.d/99-coral.rules root:root 644

step "Reload udev rules + trigger"
sudo udevadm control --reload-rules
sudo udevadm trigger
ok "udev rules reloaded and triggered"

step "Check for the Coral on USB"
if lsusb 2>/dev/null | grep -iE '1a6e:089a|18d1:9302|google|global unichip'; then
  ok "Coral present"
else
  warn "Coral not seen yet — that's fine if it isn't plugged in. Re-run after attaching it."
fi

cat <<'EOF'

  The rule sets permissions only (no symlink). Validation that a container can open
  the device happens in the Phase 4c / validation-gate steps.
EOF
