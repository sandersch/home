#!/usr/bin/env bash
# Phase 0.5 — UPS via NUT.
#
# Installs the NUT configs (root:nut 640), restores the redacted upsmon/upsd
# password from a prompt (kept OUT of the repo — placeholder __REPLACE_..__ ships
# instead), and enables the stack. NUT is host-level and must start before k3s so
# the clean-shutdown-on-power-loss hook works even if the cluster is degraded.
# shellcheck source=runbooks/phase0/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root; require_sudo; require_host_etc

PLACEHOLDER="__REPLACE_WITH_UPSMON_PASSWORD__"

step "Install non-secret NUT configs (root:nut 640)"
getent group nut >/dev/null || die "'nut' group missing — install the nut package first (03-system-prep.sh)"
# Only the secret-free files are copied straight from the repo. The two
# password-bearing files (upsd.users, upsmon.conf) are handled separately below so
# the placeholder template never lands on a live, already-configured file.
for f in nut.conf ups.conf upsd.conf; do
  install_file "nut/$f" "/etc/nut/$f" root:nut 640
done

step "Render the secret-bearing NUT configs (upsd.users, upsmon.conf)"
# The same secret appears in upsd.users (password =) and upsmon.conf (MONITOR line);
# they MUST match or upsmon can't authenticate to upsd and the shutdown hook silently
# fails. Reruns preserve an existing matching password, but always re-render the current
# repo templates so non-secret config changes are applied without rotating the secret.
# The live file is only ever replaced with a COMPLETE config, never the placeholder
# template, so an interrupted run cannot leave invalid creds.
SECRET_FILES=(upsd.users upsmon.conf)

for f in "${SECRET_FILES[@]}"; do
  grep -q "$PLACEHOLDER" "$HOST_ETC/nut/$f" || die "template $HOST_ETC/nut/$f does not contain $PLACEHOLDER"
done

existing_nut_password() {
  local users=/etc/nut/upsd.users mon=/etc/nut/upsmon.conf
  [ -f "$users" ] && [ -f "$mon" ] || return 1
  sudo grep -q "$PLACEHOLDER" "$users" "$mon" && return 1

  local p_users p_mon
  p_users="$(sudo awk '/^[[:space:]]*password[[:space:]]*=/ {print $3; exit}' "$users")"
  p_mon="$(sudo awk '$1=="MONITOR" && $2=="cp1500@localhost" {print $5; exit}' "$mon")"
  [ -n "$p_users" ] && [ "$p_users" = "$p_mon" ] || return 1
  printf '%s\n' "$p_users"
}

render_nut_secret_files() {
  local password="$1" label="$2" esc tmp
  esc="$(printf '%s' "$password" | sed 's/[&|\\]/\\&/g')"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"; unset NUTPASS esc' EXIT
  chmod 600 "$tmp"

  for f in "${SECRET_FILES[@]}"; do
    sed "s|$PLACEHOLDER|$esc|g" "$HOST_ETC/nut/$f" > "$tmp"
    grep -q "$PLACEHOLDER" "$tmp" && die "placeholder still present after substitution in $f — aborting"
    sudo install -o root -g nut -m 640 "$tmp" "/etc/nut/$f"
    ok "rendered /etc/nut/$f with $label"
  done

  rm -f "$tmp"
  trap - EXIT
}

if EXISTING_PASS="$(existing_nut_password)"; then
  render_nut_secret_files "$EXISTING_PASS" "the existing live password"
  unset EXISTING_PASS
else
  [ -t 0 ] || die "password needed but no TTY to prompt — run interactively"
  read -r -s -p "  NUT upsmon password (from password manager): " NUTPASS; echo
  [ -n "$NUTPASS" ] || die "empty password"
  render_nut_secret_files "$NUTPASS" "the supplied password"
  unset NUTPASS
fi

step "Enable + start the NUT stack"
sudo systemctl enable --now nut-driver-enumerator nut-server nut-monitor
ok "nut-driver-enumerator, nut-server, nut-monitor enabled"

step "Verify the UPS is reporting"
if sudo upsc cp1500 2>/dev/null | grep -q .; then
  sudo upsc cp1500 | grep -E 'battery.charge|ups.status|battery.runtime' || true
  ok "cp1500 reporting"
else
  die "upsc cp1500 returned nothing — check the USB cable and 'upsc -l', then 'journalctl -u nut-server'"
fi
