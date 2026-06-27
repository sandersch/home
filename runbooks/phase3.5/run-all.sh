#!/usr/bin/env bash
# Run the Phase 3.5 app-data migration steps in dependency order.
# shellcheck source=runbooks/phase3.5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEPS=(
  00-preflight.sh
  01-copy-configs.sh
  02-validate-copy.sh
)

step "Phase 3.5 - final app-data migration (${#STEPS[@]} steps)"
cat <<EOF
This copies stopped-host app config from:
  $PHASE35_SRC

to local NVMe under:
  $PHASE35_DEST_ROOT

It migrates Plex, Radarr, Sonarr, and Prowlarr only. The copy step uses rsync
--delete, so destination config directories are made to match the archive.
EOF

confirm "Run Phase 3.5 migration now?" || die "aborted"

for s in "${STEPS[@]}"; do
  step "=== $s ==="
  if [ "$s" = "01-copy-configs.sh" ]; then
    PHASE35_ASSUME_YES=1 bash "$PHASE_DIR/$s"
  else
    bash "$PHASE_DIR/$s"
  fi
done

step "Phase 3.5 migration complete"
cat <<'EOF'
Next Phase 4 work:
  - Deploy the download pod first: Gluetun + SABnzbd + Prowlarr + Radarr + Sonarr.
  - Deploy Plex with /opt/plex/config and do not set PLEX_CLAIM.
  - Validate Plex metadata/auth, Quick Sync, *arr history/settings, VPN egress, and
    a Prowlarr -> Radarr/Sonarr -> SABnzbd test flow.
EOF
