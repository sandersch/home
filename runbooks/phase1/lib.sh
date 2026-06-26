#!/usr/bin/env bash
# Phase 1 helpers.
#
# Phase 1 runs on the minis host and installs the canonical host-level camera
# isolation config from host/minis/etc/. It intentionally does not configure the
# Catalyst switch; that is network gear and has its own checklist in this dir.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

assert_phase1_source_files() {
  local f
  for f in \
    nftables.conf \
    sysctl.d/99-camera-no-ipv6.conf \
    dnsmasq.d/cameras.conf \
    chrony/conf.d/cameras.conf; do
    [ -f "$HOST_ETC/$f" ] || die "missing canonical host config: $HOST_ETC/$f"
  done
  ok "Phase 1 canonical host config is present"
}

# The camera DHCP and NTP config ship as drop-ins only (no main config in the repo),
# so they take effect ONLY if the stock main config includes their directory. If that
# include is ever missing, the daemon starts cleanly and 'service_active' passes while
# our drop-in is silently never parsed — dnsmasq serves no DHCP, or chrony refuses to
# serve the segment during a WAN outage and the cameras drift. Ensure the include here
# so a missing distro default is repaired before validation and service restart.
ensure_dropin_included() {
  local label="$1" main="$2" regex="$3" dir="$4" include_line="$5"
  sudo test -f "$main" \
    || die "$label main config $main is missing; the $dir drop-in would be ignored"
  if sudo grep -Eqs "$regex" "$main"; then
    ok "$main includes $dir (camera drop-in will be read)"
  else
    printf '\n# Homelab camera %s drop-ins\n%s\n' "$label" "$include_line" \
      | sudo tee -a "$main" >/dev/null
    ok "added $dir include to $main"
  fi
}

ensure_camera_dropins_included() {
  step "Ensure main configs include the camera drop-in dirs"
  ensure_dropin_included dnsmasq /etc/dnsmasq.conf \
    '^[[:space:]]*conf-dir=.*dnsmasq\.d' /etc/dnsmasq.d \
    'conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new'
  ensure_dropin_included chrony /etc/chrony/chrony.conf \
    '^[[:space:]]*confdir[[:space:]].*conf\.d' /etc/chrony/conf.d \
    'confdir /etc/chrony/conf.d'
}
