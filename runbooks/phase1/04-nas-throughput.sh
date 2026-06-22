#!/usr/bin/env bash
# Phase 1.4 - NAS throughput spot checks.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
# No require_sudo: every check here (iperf3, dd to NFS, findmnt) runs as the user, so
# priming sudo would only add a needless password prompt.
require_tools getent timeout iperf3 findmnt dd sync rm

NAS_HOST="media.nfs.service.matrix"
TEST_DIR="/mnt/media/to_archive"
TEST_FILE="$TEST_DIR/.phase1-throughput-test.$$"

step "Resolve NAS hostname"
getent hosts "$NAS_HOST" || die "$NAS_HOST does not resolve"
ok "$NAS_HOST resolves"

step "Confirm /mnt/media is mounted"
findmnt --target "$TEST_DIR" >/dev/null || die "$TEST_DIR is not mounted"
[ -d "$TEST_DIR" ] || die "$TEST_DIR does not exist on the NAS export"
[ -w "$TEST_DIR" ] || die "$TEST_DIR is not writable (need write access for the spot check)"
ok "$TEST_DIR is mounted and writable"

step "iperf3 client test"
cat <<EOF
Start an iperf3 server on the NAS first:
  iperf3 -s

Expected result today is roughly 940 Mbits/sec because this path is 1 GbE.
EOF
if confirm "Run iperf3 -c $NAS_HOST now?"; then
  timeout 30 iperf3 -c "$NAS_HOST" || die "iperf3 client test failed"
else
  warn "skipped iperf3; run manually before proceeding if NAS throughput is uncertain"
fi

step "NFS read/write spot check"
cat <<EOF
This writes and deletes a temporary 256 MiB file:
  $TEST_FILE
EOF
confirm "Run the NFS write/read spot check now?" || die "NFS spot check skipped"

cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT

timeout 60 dd if=/dev/zero of="$TEST_FILE" bs=1M count=256 status=progress conv=fsync \
  || die "NFS write test failed"
sync
timeout 60 dd if="$TEST_FILE" of=/dev/null bs=1M status=progress \
  || die "NFS read test failed"
rm -f "$TEST_FILE"
trap - EXIT
ok "NFS read/write spot check completed"
