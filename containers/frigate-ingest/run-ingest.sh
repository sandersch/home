#!/bin/sh
set -eu
die() { echo "frigate ingestion guard: $*" >&2; exit 1; }
vault=${VAULT_PATH:-/data/vault}
source_dir=${SOURCE_PATH:-/data/frigate-exports}
mountinfo=${MOUNTINFO_PATH:-/proc/self/mountinfo}
expected_vault=${EXPECTED_VAULT_SOURCE:-/dev/mapper/vault}
expected_root=${EXPECTED_ROOT_SOURCE:-/dev/mapper/vg0-root}
vault_uuid=${EXPECTED_VAULT_UUID:-d926696b-2f04-45cb-805c-40af30dc156d}
source_device=${EXPECTED_SOURCE_DEVICE:-/dev/mapper/hoardvg-frigate}
copier=${COPIER_BIN:-/usr/local/bin/frigate-ingest}
sentinel_metadata=${EXPECTED_SENTINEL_METADATA:-0:0:444}
record="$(awk -v target="$vault" '$5 == target { for (i=7;i<=NF;i++) if ($i=="-") { print $4 "\t" $(i+1) "\t" $(i+2) "\t" $6 "\t" $(i+3); break } }' "$mountinfo" | tail -n 1)"
[ -n "$record" ] || die "$vault has no mountinfo record"
IFS="$(printf '\t')" read -r root fstype source opts superopts <<EOF
$record
EOF
if [ "$fstype" = ext4 ] && [ "$source" = "$expected_root" ] && [ "$root" = /mnt/vault ]; then
  echo "vault is locked; ingestion skipped"
  exit 0
fi
[ "$fstype" = ext4 ] && [ "$source" = "$expected_vault" ] \
  || die "unexpected vault mount identity: $fstype $source $root"
case ",$opts,$superopts," in *,rw,*) ;; *) die "vault mount is not writable" ;; esac
sentinel="$vault/.vault-sentinel"
[ -f "$sentinel" ] && [ ! -L "$sentinel" ] || die "invalid vault sentinel"
[ "$(stat -c '%u:%g:%a' "$sentinel")" = "$sentinel_metadata" ] || die "invalid vault sentinel metadata"
grep -qxF 'vault-contract-version=3' "$sentinel" || die "sentinel contract is not v3"
grep -qxF "filesystem-uuid=$vault_uuid" "$sentinel" || die "sentinel UUID mismatch"
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] \
  || die "Frigate export directory is missing or a symlink"
source_record="$(awk -v target="$source_dir" '$5 == target { for (i=7;i<=NF;i++) if ($i=="-") { print $(i+1) "\t" $(i+2) "\t" $6 "\t" $(i+3); break } }' "$mountinfo" | tail -n 1)"
[ -n "$source_record" ] || die "Frigate source is not a mount"
IFS="$(printf '\t')" read -r source_fstype source_name source_opts source_super <<EOF
$source_record
EOF
[ "$source_fstype" = ext4 ] && [ "$source_name" = "$source_device" ] \
  || die "unexpected Frigate source mount: $source_fstype $source_name"
case ",$source_opts,$source_super," in *,ro,*) ;; *) die "Frigate source is not read-only" ;; esac
[ -r "$source_dir" ] || die "Frigate source is inaccessible"
destination="$vault/frigate-exports"
[ -d "$destination" ] && [ ! -L "$destination" ] \
  || die "vault archive directory is invalid"
exec "$copier" "$source_dir" "$destination"
