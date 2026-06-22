#!/usr/bin/env bash
# Phase 0.1 (post-SSH) — set the hostname and harden SSH.
#
# The node name k3s derives from the hostname is load-bearing: every app PV pins
# nodeAffinity to kubernetes.io/hostname=minis (build-plan.md 0.1 / 2.1).
#
# SSH is assumed already up and reachable (that's where this runbook starts). This
# step applies the key-only-auth drop-in and restarts sshd. PasswordAuthentication no
# will LOCK YOU OUT if your key isn't already authorized — guarded below.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc

step "Set hostname to 'minis'"
if [ "$(hostnamectl --static)" = "minis" ]; then
  ok "hostname already 'minis'"
else
  sudo hostnamectl set-hostname minis
  ok "hostname set to 'minis'"
fi

step "Harden SSH (key-only auth, no root login)"
# Guard: with PasswordAuthentication off, a missing authorized_keys = lockout.
# Check before installing the drop-in so a later reboot/package restart cannot
# activate key-only auth on an account with no key.
AUTHKEYS="$HOME/.ssh/authorized_keys"
if [ ! -s "$AUTHKEYS" ]; then
  die "no authorized_keys for $(id -un) — copy your key up first (ssh-copy-id), then re-run"
fi
ok "authorized_keys present for $(id -un)"

install_file ssh/sshd_config.d/10-homelab.conf /etc/ssh/sshd_config.d/10-homelab.conf root:root 644

# Validate sshd config before any restart.
sudo sshd -t || die "sshd config test failed — NOT restarting (you'd be locked out)"
ok "sshd -t passed"

cat <<'EOF'

  About to restart sshd with PasswordAuthentication=no.
  KEEP THIS SESSION OPEN. Open a SECOND terminal and confirm a key login works
  BEFORE closing this one. If the new session fails, revert with:
      sudo rm /etc/ssh/sshd_config.d/10-homelab.conf && sudo systemctl restart ssh
EOF
if confirm "Restart sshd now?"; then
  sudo systemctl restart ssh
  ok "sshd restarted — verify a fresh key login in another terminal now"
else
  warn "skipped sshd restart; config is in place but not yet active. Restart manually: sudo systemctl restart ssh"
fi
