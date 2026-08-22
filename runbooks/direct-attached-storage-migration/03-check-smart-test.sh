#!/usr/bin/env bash
# Report one concise SMART long-test sample for a single ATA or SAS disk.

set -uo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: 03-check-smart-test.sh /dev/disk/by-id/<whole-disk-id>

Run this script repeatedly with watch or a shell loop. It only queries SMART data;
it does not start, stop, or otherwise alter a self-test.
EOF
}

if (($# != 1)); then
  usage >&2
  exit 2
fi

disk="$1"

command -v smartctl >/dev/null 2>&1 || {
  echo "ERROR: smartctl is required" >&2
  exit 2
}
command -v sudo >/dev/null 2>&1 || {
  echo "ERROR: sudo is required" >&2
  exit 2
}

if [[ "$disk" != /dev/disk/by-id/* || "$disk" == *-part[0-9]* ]]; then
  echo "ERROR: use a stable /dev/disk/by-id whole-disk path: $disk" >&2
  exit 2
fi
if [[ ! -b "$disk" ]]; then
  echo "ERROR: disk is missing or is not a block device: $disk" >&2
  exit 2
fi

smartctl_rc=0
report="$(sudo smartctl -x "$disk" 2>&1)" || smartctl_rc=$?

# smartctl bits 0 and 1 mean the command could not be parsed or the device could
# not be opened. Higher bits describe SMART health/log findings that we still
# want to parse and display.
if ((smartctl_rc & 3)); then
  printf '%s\n' "$report" >&2
  echo "ERROR: smartctl could not query $disk (exit $smartctl_rc)" >&2
  exit 2
fi

serial="$({
  sed -nE 's/^Serial [Nn]umber:[[:space:]]*//p' <<<"$report" || true
} | head -n 1)"
[[ -n "$serial" ]] || serial="$(basename "$disk")"

temperature="$({
  sed -nE \
    -e 's/^Current (Drive )?Temperature:[[:space:]]*([0-9]+).*/\2/p' \
    -e 's/^194 Temperature_Celsius.*[[:space:]]([0-9]+)([[:space:]].*)?$/\1/p' \
    <<<"$report" || true
} | head -n 1)"
if [[ "$temperature" =~ ^[0-9]+$ ]]; then
  temp_display="${temperature}C"
else
  temp_display="unknown"
fi

trip_temperature="$({
  sed -nE \
    's/^Drive Trip Temperature:[[:space:]]*([0-9]+).*/\1/p' \
    <<<"$report" || true
} | head -n 1)"

remaining="$({
  sed -nE \
    -e 's/^[[:space:]]*([0-9]+)% of test remaining.*/\1/p' \
    -e 's/^Self-test execution status:[[:space:]]*([0-9]+)% of test remaining.*/\1/p' \
    <<<"$report" || true
} | head -n 1)"

latest_long="$({
  grep -E '^# *1[[:space:]]+(Extended offline|Background long)' \
    <<<"$report" || true
} | head -n 1)"

if grep -Eq 'Self-test routine in progress|Self test in progress' <<<"$report"; then
  state="RUNNING"
  if [[ "$remaining" =~ ^[0-9]+$ ]]; then
    remaining_display="${remaining}%"
  else
    remaining_display="unknown"
  fi
  result=0
elif grep -Eq 'Completed without error|Background long[[:space:]]+Completed[[:space:]]' \
  <<<"$latest_long"; then
  state="PASSED"
  remaining_display="0%"
  result=0
elif [[ -n "$latest_long" ]]; then
  state="FAILED"
  remaining_display="-"
  result=1
else
  state="IDLE"
  remaining_display="-"
  result=1
fi

printf '%s  serial=%s  state=%s  remaining=%s  temp=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
  "$serial" "$state" "$remaining_display" "$temp_display"

if [[ -n "$latest_long" && "$state" != "RUNNING" ]]; then
  printf '  latest: %s\n' "$latest_long"
fi

if [[ "$temperature" =~ ^[0-9]+$ && "$trip_temperature" =~ ^[0-9]+$ ]] && \
  ((temperature >= trip_temperature)); then
  printf 'ALERT: temperature %dC is at or above the drive trip temperature %dC\n' \
    "$temperature" "$trip_temperature" >&2
  result=1
fi

exit "$result"
