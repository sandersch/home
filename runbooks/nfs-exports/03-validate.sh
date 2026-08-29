#!/usr/bin/env bash
# NFS exports 03 - the gate. Automated server-side checks plus attended client tests.
#
# Run on minis. The client-side sections need a second machine on VLAN 20 or 30, and
# the negative tests need a host on VLAN 60 or 80 (or a Tailnet client).
# shellcheck source=runbooks/nfs-exports/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo
require_host_etc
require_tools exportfs nft ss systemctl findmnt readlink timeout awk

step "Server identity and version lockdown"
assert_nfs_mounts_ready
service_active nfs-server
service_active nfs-mountd
assert_nfs_versions_locked
assert_nfs_bind_addresses
assert_nfs_exports_file
assert_nfs_export_options
assert_nfs_firewall

step "Confirm nothing listens on the camera segment"
for addr in 192.168.105.1 192.168.1.2; do
  if timeout 2 bash -c "</dev/tcp/$addr/2049" 2>/dev/null; then
    die "TCP 2049 is reachable on the camera-segment address $addr"
  fi
  ok "$addr:2049 is closed"
done

step "Confirm the masked v3 units stayed down"
for unit in "${NFS_MASKED_UNITS[@]}"; do
  systemctl is-active --quiet "$unit" && die "$unit is active; NFSv4-only does not need it"
  ok "$unit is inactive"
done

step "Record the drop-counter baseline for the negative tests below"
sudo nft list table inet nfs_access | grep -E 'counter packets' || true

cat <<'TEXT'

--- Attended client tests -------------------------------------------------------

On a VLAN 30 workstation (or another VLAN 20 server):

  sudo mount -t nfs4 -o vers=4.2,sec=sys,hard 10.137.20.5:/mnt/media /mnt/media
  sudo mount -t nfs4 -o vers=4.2,sec=sys,hard 10.137.20.5:/mnt/games /mnt/games
  touch /mnt/media/.nfs-write-test && rm /mnt/media/.nfs-write-test
  touch /mnt/games/.nfs-write-test && rm /mnt/games/.nfs-write-test

Then prove v3 is off. A bare "the mount failed" proves nothing -- a missing directory,
a busy mountpoint, or a typo all fail too. Use a FRESH mountpoint and a positive control
on that same mountpoint, so the only thing that differs between the two attempts is the
protocol version. Paste this whole block on the client:

  d=$(mktemp -d)
  echo "--- v4.2 (positive control; MUST succeed) ---"
  sudo mount -t nfs4 -o vers=4.2,sec=sys,hard 10.137.20.5:/mnt/media "$d" \
    && echo "CONTROL OK: v4.2 mounted on $d" || echo "CONTROL FAILED: fix this first"
  sudo umount "$d" 2>/dev/null
  echo "--- v3 (MUST be refused) ---"
  sudo mount -t nfs -o vers=3 10.137.20.5:/mnt/media "$d" 2>&1 | tee /tmp/v3-test.log
  if mountpoint -q "$d"; then
    echo "VERDICT: FAIL - v3 mounted; the version lockdown is not in effect"
    sudo umount "$d"
  elif grep -qiE 'not supported|Protocol not supported|Connection refused|Program not registered|RPC' /tmp/v3-test.log; then
    echo "VERDICT: PASS - v3 refused at the protocol/RPC layer"
  else
    echo "VERDICT: INCONCLUSIVE - mount failed for an unrelated reason:"
    cat /tmp/v3-test.log
  fi
  rmdir "$d"

Expected: the control mounts, then v3 prints VERDICT: PASS. With rpcbind masked the v3
error is usually "Connection refused" or "RPC: Program not registered"; with rpcbind
running it is "requested NFS version or transport protocol is not supported". Both are
genuine refusals. Anything else is INCONCLUSIVE -- re-run rather than passing the gate.

Then the squash gates.

/mnt/media is root_squash, and its mount root is 1000:100 0775. Remote root is mapped
to the anonymous 65534:65534, which is "other" on that directory -- so this MUST FAIL
with "Permission denied". Success would mean root was NOT squashed:

  sudo touch /mnt/media/.root-squash-test

As uid 1000 on the client (the owner of the tree), this MUST SUCCEED:

  touch /mnt/media/.uid1000-test

/mnt/games is all_squash to 1000:1000 and its mount root is 1000:1000 0755, so every
remote user -- including root -- lands on the owner. This MUST SUCCEED whatever uid
you run it as:

  sudo touch /mnt/games/.all-squash-test

TEXT

confirm "Did both exports mount read/write from a VLAN 20 or 30 client?" \
  || die "client mount validation did not pass"
confirm "Did the v4.2 positive control mount succeed on the fresh mountpoint?" \
  || die "the control mount failed; the v3 result is uninterpretable until a v4.2 mount works from this client"
confirm "Did the v3 attempt print 'VERDICT: PASS'?" \
  || die "NFSv3 was not cleanly refused; an INCONCLUSIVE or FAIL verdict does not satisfy this gate"

step "Check squash results on the server"
# root_squash on /mnt/media is proven by the ABSENCE of the file: uid 0 is mapped to the
# anonymous 65534:65534 (exports(5) default), which is "other" against a 1000:100 0775
# mount root and therefore cannot create anything there. A file appearing here means
# either no_root_squash (owner would be root) or an unintended all_squash to 1000.
if [ -e /mnt/media/.root-squash-test ]; then
  owner="$(stat -c '%U (uid %u)' /mnt/media/.root-squash-test)"
  sudo rm -f /mnt/media/.root-squash-test
  die "client root created /mnt/media/.root-squash-test as $owner; remote root must be squashed and denied at the 1000:100 0775 mount root"
fi
ok "/mnt/media rejected the client's root write; remote root is squashed"

confirm "Did 'sudo touch /mnt/media/.root-squash-test' fail with Permission denied?" \
  || die "the client root write did not fail as expected; check the media export's squash options"

# The positive halves: uid 1000 owns /mnt/media, and every uid is squashed to 1000 on
# /mnt/games, so both of these must exist and be owned by uid 1000.
for path in /mnt/media/.uid1000-test /mnt/games/.all-squash-test; do
  [ -e "$path" ] || die "$path was not created; re-run the client-side squash tests"
  actual_uid="$(stat -c '%u' "$path")"
  actual_gid="$(stat -c '%g' "$path")"
  [ "$actual_uid" = "1000" ] \
    || die "$path is owned by uid $actual_uid, expected 1000"
  ok "$path is owned by uid $actual_uid, gid $actual_gid as expected"
done
# all_squash pins the group too, so /mnt/games writes must land on gid 1000 whatever
# supplementary groups the client user had.
games_gid="$(stat -c '%g' /mnt/games/.all-squash-test)"
[ "$games_gid" = "1000" ] \
  || die "/mnt/games/.all-squash-test has gid $games_gid, expected 1000 from anongid"
ok "/mnt/games squashed the write to 1000:1000"

sudo rm -f /mnt/media/.uid1000-test /mnt/games/.all-squash-test
ok "squash policy behaves as configured; test files removed"

cat <<'TEXT'

--- Attended negative tests -----------------------------------------------------

From an IoT (VLAN 60) or Guest (VLAN 80) host, and again from a Tailnet client:

  nc -vz -w 3 10.137.20.5 2049

Expected: connection times out in every case. IoT and Guest are already dropped by
UDM Rules 910/900; the Tailnet has no allow at all in nfs_access.

TEXT

confirm "Did TCP 2049 time out from IoT/Guest and from the Tailnet?" \
  || die "an unintended VLAN can reach the export; stop and fix nfs_access before continuing"

step "Confirm the drop counters moved"
sudo nft list table inet nfs_access | grep -E 'counter packets' || true
confirm "Did the nfs_access drop counters increment during the negative tests?" \
  || warn "counters did not move; the traffic may have been dropped upstream by the UDM, which is also correct"

step "Re-run the neighbouring gates that share this host state"
cat <<'TEXT'
Run these and confirm they still pass:
  ../phase1/03-camera-segment-validation.sh   camera isolation unaffected by nfs_access
  ../phase3/03-validation-gate.sh             local hostPath workloads unaffected
  ../phase1/04-direct-storage-throughput.sh   local throughput unchanged by nfsd
TEXT
confirm "Did the camera-isolation, hostPath, and throughput gates all still pass?" \
  || die "a neighbouring gate regressed; do not leave the exports in service"

ok "NFS export validation complete; run ./04-validate-monitoring.sh"
