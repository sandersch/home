#!/usr/bin/env bash
# Phase 4 host setup - install Frigate's config into the host path backing its PVC.
#
# The Frigate Deployment mounts frigate-config-pvc at /config. That PVC is backed by
# /opt/frigate/config on minis, so config.yml must exist there before first rollout.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_sudo

src="$PHASE4_FRIGATE_DIR/config.yml"
dest="/opt/frigate/config/config.yml"

[ -f "$src" ] || die "missing Frigate config source: $src"

step "Install Frigate config into the config PVC backing path"
sudo install -D -o root -g root -m 0644 "$src" "$dest"
ok "installed $dest from apps/frigate/config.yml"

cat <<'EOF'

Next:
- Reconcile the apps Flux target.
- Confirm Frigate can read /config/config.yml after the pod starts.
EOF
