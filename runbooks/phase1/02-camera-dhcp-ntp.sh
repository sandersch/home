#!/usr/bin/env bash
# Phase 1.2 and 1.3 - camera DHCP with dnsmasq and camera NTP with chrony.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools ip systemctl dnsmasq chronyc ss
assert_phase0_network_settled

step "Install camera dnsmasq and chrony configs"
install_file dnsmasq.d/cameras.conf /etc/dnsmasq.d/cameras.conf root:root 644
install_file chrony/conf.d/cameras.conf /etc/chrony/conf.d/cameras.conf root:root 644

# The drop-ins above only take effect if the main configs include their dirs.
ensure_camera_dropins_included

step "Validate dnsmasq config"
sudo dnsmasq --test
ok "dnsmasq config test passed"

step "Enable and restart dnsmasq"
sudo systemctl enable --now dnsmasq
sudo systemctl restart dnsmasq
service_active dnsmasq

step "Disable systemd-timesyncd before chrony owns host time"
# build-plan.md 1.3: chrony supersedes Ubuntu's default systemd-timesyncd, which is an
# SNTP client only and cannot serve the camera segment. Disable it before restarting
# chrony so the apply path leaves the host in the intended steady state.
if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
  sudo systemctl disable --now systemd-timesyncd
fi
if systemctl is-active --quiet systemd-timesyncd; then
  die "systemd-timesyncd is still active after disable; chrony must be the time daemon"
fi
ok "systemd-timesyncd is not active"

step "Enable and restart chrony"
sudo systemctl enable --now chrony
sudo systemctl restart chrony
service_active chrony

step "Confirm chrony, not systemd-timesyncd, is the active time daemon"
# timedatectl reports the real timekeeping owner; on a correct host this is chrony.
if timedatectl show -p NTP --value 2>/dev/null | grep -qx yes; then
  ok "timedatectl reports network time synchronization is on (chrony)"
else
  warn "timedatectl does not report NTP as enabled; check 'timedatectl' and 'chronyc tracking'"
fi

step "Confirm listeners"
sudo ss -lunp | awk '$4 ~ /:(67|123)$/ { print }' || true
if sudo ss -lunp | awk '$4 ~ /:67$/ && /dnsmasq/ { found=1 } END { exit !found }'; then
  ok "dnsmasq is listening for DHCP"
else
  warn "could not confirm dnsmasq on UDP/67 via ss; check journalctl -u dnsmasq if DHCP fails"
fi
if sudo ss -lunp | awk '$4 ~ /:123$/ && /chrony/ { found=1 } END { exit !found }'; then
  ok "chrony is listening for NTP"
else
  warn "could not confirm chrony on UDP/123 via ss; check journalctl -u chrony if NTP tests fail"
fi

step "Show chrony source state"
chronyc sources || true

cat <<'EOF'

Next:
  - Complete/confirm Catalyst protected-port isolation before connecting real cameras.
  - Run 03-camera-segment-validation.sh with a test device on the camera segment.

The committed dnsmasq config has no camera dhcp-host reservations yet. Add one
reservation per camera in host/minis/etc/dnsmasq.d/cameras.conf before Frigate.
EOF
