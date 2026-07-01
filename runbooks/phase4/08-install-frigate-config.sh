#!/usr/bin/env bash
# Legacy Phase 4 helper - install Frigate's config into the host path backing its PVC.
#
# Frigate now receives /config/config.yml from the generated frigate-config ConfigMap.
# This script is only for manually seeding the host path if a rollback needs the old
# PVC-backed config file.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo

src="$PHASE4_FRIGATE_DIR/config.yml"
dest="/opt/frigate/config/config.yml"

[ -f "$src" ] || die "missing Frigate config source: $src"

step "Install legacy Frigate config copy into the config PVC backing path"
sudo install -D -o root -g root -m 0644 "$src" "$dest"
ok "installed $dest from apps/frigate/config.yml"

cat <<'EOF'

Next:
- Normal GitOps config changes use apps/frigate/config.yml via the generated ConfigMap.
- This host-path copy is only used if the Deployment is rolled back to PVC-backed config.
EOF
