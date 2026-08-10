#!/usr/bin/env bash
# Phase 1.4 - direct-attached storage throughput spot check.
# shellcheck source=runbooks/phase1/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools timeout findmnt readlink dd sync rm

TEST_DIR="/mnt/media"
TEST_FILE="$TEST_DIR/.phase1-throughput-test.$$"

step "Confirm direct-attached /mnt/media identity"
assert_direct_mount_layout /mnt/media /dev/mapper/hoardvg-medialv \
  0a94d86c-76a0-44b5-bc52-930d97ab155f
[ -w "$TEST_DIR" ] || die "$TEST_DIR is not writable (need write access for the spot check)"
ok "$TEST_DIR is directly mounted and writable"

step "Direct-storage read/write spot check"
cat <<EOF
This writes and deletes a temporary 256 MiB file:
  $TEST_FILE
EOF
confirm "Run the direct-storage write/read spot check now?" || die "storage spot check skipped"

cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT

timeout 60 dd if=/dev/zero of="$TEST_FILE" bs=1M count=256 status=progress conv=fsync \
  || die "direct-storage write test failed"
sync
timeout 60 dd if="$TEST_FILE" of=/dev/null bs=1M status=progress \
  || die "direct-storage read test failed"
rm -f "$TEST_FILE"
trap - EXIT
ok "direct-storage read/write spot check completed"
