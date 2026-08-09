#!/usr/bin/env bash
# Report per-disk and aggregate status for the bulk-array extended SMART tests.

set -uo pipefail
export LC_ALL=C

disks=(
  /dev/disk/by-id/ata-HGST_HDN724040ALE640_PK1334PEHGXSTS
  /dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E7KFCARZ
  /dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX42D642T1VE
  /dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E0631383
  /dev/disk/by-id/ata-ST4000DM000-1F2168_S300RM4M
  /dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E0624669
  /dev/disk/by-id/ata-ST4000NM0024-1HT178_Z4F07WQV
  /dev/disk/by-id/ata-ST4000NM0024-1HT178_Z4F08A4E
  /dev/disk/by-id/ata-HGST_HUS724040ALA640_PN1334PCKAJ33S
  /dev/disk/by-id/ata-HGST_HUS724040ALA640_PN2334PCKRNVJB
  /dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K2UFNUDN
  /dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K5TY8U9P
  /dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX42D540749F
  /dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WXJ2AB2HYH10
  /dev/disk/by-id/ata-WDC_WD40EFPX-68C6CN0_WD-WX52AA2RSJYC
)

command -v smartctl >/dev/null 2>&1 || {
  echo "ERROR: smartctl is required" >&2
  exit 1
}
command -v sudo >/dev/null 2>&1 || {
  echo "ERROR: sudo is required" >&2
  exit 1
}
sudo -v || exit 1

running=0
passed=0
failed=0
idle=0
query_errors=0
remaining_sum=0
highest_temp=0

printf '%-22s %-11s %10s %8s\n' \
  "SERIAL" "STATE" "REMAINING" "TEMP"
printf '%-22s %-11s %10s %8s\n' \
  "----------------------" "-----------" "----------" "--------"

for disk in "${disks[@]}"; do
  if [[ ! -b "$disk" ]]; then
    printf '%-22s %-11s %10s %8s\n' \
      "$(basename "$disk")" "MISSING" "-" "-"
    ((query_errors += 1))
    continue
  fi

  report="$(sudo smartctl -x "$disk" 2>&1)"

  serial="$({
    sed -n 's/^Serial Number:[[:space:]]*//p' <<<"$report" || true
  } | head -n 1)"
  [[ -n "$serial" ]] || serial="$(basename "$disk")"

  temperature="$({
    sed -nE \
      's/^[[:space:]]*Current Temperature:[[:space:]]*([0-9]+).*/\1/p' \
      <<<"$report" || true
  } | head -n 1)"
  if [[ "$temperature" =~ ^[0-9]+$ ]]; then
    temp_display="${temperature}C"
    ((temperature > highest_temp)) && highest_temp="$temperature"
  else
    temp_display="unknown"
  fi

  if ! grep -Fq 'Self-test execution status:' <<<"$report"; then
    state="QUERY-ERROR"
    remaining_display="-"
    ((query_errors += 1))
  elif grep -Fq 'Self-test routine in progress' <<<"$report"; then
    remaining="$({
      sed -nE \
        's/^[[:space:]]*([0-9]+)% of test remaining.*/\1/p' \
        <<<"$report" || true
    } | head -n 1)"
    [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0

    state="RUNNING"
    remaining_display="${remaining}%"
    ((running += 1))
    ((remaining_sum += remaining))
  else
    latest_extended="$({
      grep -E '^# *1[[:space:]]+Extended offline' <<<"$report" || true
    } | head -n 1)"

    if grep -Fq 'Completed without error' <<<"$latest_extended"; then
      state="PASSED"
      remaining_display="0%"
      ((passed += 1))
    elif [[ -n "$latest_extended" ]]; then
      state="FAILED"
      remaining_display="-"
      ((failed += 1))
    else
      state="IDLE"
      remaining_display="-"
      ((idle += 1))
    fi
  fi

  printf '%-22s %-11s %10s %8s\n' \
    "$serial" "$state" "$remaining_display" "$temp_display"
done

printf '\nSummary\n'
printf '  Total disks:              %d\n' "${#disks[@]}"
printf '  Running:                  %d\n' "$running"
printf '  Passed:                   %d\n' "$passed"
printf '  Failed/aborted:           %d\n' "$failed"
printf '  Idle without result:      %d\n' "$idle"
printf '  Query errors:             %d\n' "$query_errors"

if ((running > 0)); then
  printf '  Average remaining:        %d%%\n' \
    "$((remaining_sum / running))"
fi

if ((highest_temp > 0)); then
  printf '  Highest temperature:      %dC\n' "$highest_temp"
fi

if ((failed > 0 || idle > 0 || query_errors > 0)); then
  exit 1
fi
