#!/bin/sh

set -eu

# shellcheck disable=SC2034 # These paths are consumed by scripts sourcing this file.
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC2034 # Used by scripts that source this library.
HOST_SOURCE="$REPO_ROOT/host/bastion"
STATE_FILE=/var/db/bastion-wired-nic
# shellcheck disable=SC2034 # Used by scripts that source this library.
GATE_FILE=/var/db/bastion-preflight

step() { printf '\n==> %s\n' "$*"; }
ok() { printf 'ok: %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root from the Wyse local console"
}

discover_wired_nic() {
  candidates=
  for iface in $(ifconfig -a | sed -n 's/^\([a-z][a-z0-9]*[0-9]\):.*/\1/p'); do
    case "$iface" in
      lo*|pflog*|enc*|vlan*|bridge*|vether*|tap*|tun*|wg*|pppoe*|trunk*|carp*|pair*|gre*|gif*)
        continue
        ;;
    esac
    details=$(ifconfig "$iface")
    printf '%s\n' "$details" | grep -q 'lladdr ' || continue
    printf '%s\n' "$details" | grep -q 'media:' || continue
    printf '%s\n' "$details" | grep -q 'ieee80211' && continue
    candidates="${candidates}${candidates:+ }$iface"
  done

  # Word splitting is deliberate: exactly one physical wired interface is valid.
  # shellcheck disable=SC2086
  set -- $candidates
  [ "$#" -eq 1 ] || die "expected exactly one wired NIC; found ${#}: ${candidates:-none}"
  WIRED_IF=$1
  WIRED_MAC=$(ifconfig "$WIRED_IF" | awk '/lladdr / { print $2; exit }')
  [ -n "$WIRED_MAC" ] || die "could not read the MAC for $WIRED_IF"
}

read_recorded_nic() {
  [ -r "$STATE_FILE" ] || die "missing $STATE_FILE; run 00-preflight.sh first"
  # read returns 1 at EOF when the last line has no newline, even after assigning it.
  read -r WIRED_IF WIRED_MAC < "$STATE_FILE" || true
  [ -n "${WIRED_IF:-}" ] && [ -n "${WIRED_MAC:-}" ] || die "invalid $STATE_FILE"
}
