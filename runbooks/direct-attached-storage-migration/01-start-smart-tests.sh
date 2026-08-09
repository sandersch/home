#!/usr/bin/env bash
# Start extended SMART tests on every recorded bulk-array disk that does not
# already have a self-test in progress. This intentionally permits all 15 tests
# to run concurrently; see README.md for the attended migration safety boundary.

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

started=0
skipped=0
failed=0

for disk in "${disks[@]}"; do
  printf '\n=== %s ===\n' "$disk"

  if [[ ! -b "$disk" ]]; then
    echo "ERROR: path is not a block device"
    ((failed += 1))
    continue
  fi

  status="$(sudo smartctl -c "$disk" 2>&1)"

  if ! grep -Fq 'Self-test execution status:' <<<"$status"; then
    echo "ERROR: could not determine self-test status"
    printf '%s\n' "$status"
    ((failed += 1))
    continue
  fi

  if grep -Fq 'Self-test routine in progress' <<<"$status"; then
    echo "SKIP: a self-test is already running"
    ((skipped += 1))
    continue
  fi

  result="$(sudo smartctl -t long "$disk" 2>&1)"
  printf '%s\n' "$result"

  if grep -Fq 'Testing has begun' <<<"$result"; then
    ((started += 1))
  else
    echo "ERROR: smartctl did not confirm that testing began"
    ((failed += 1))
  fi
done

printf '\nStarted: %d  Already running: %d  Failed: %d\n' \
  "$started" "$skipped" "$failed"

((failed == 0))
