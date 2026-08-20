#!/usr/bin/env bash
# Phase 4 validation - check RomM after Flux reconciles it.
# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

step "Verify RomM rollout"
kubectl -n media rollout status deploy/romm --timeout=300s
ok "RomM rollout is complete"

step "Verify RomM storage"
kubectl -n media get pvc romm-data-pvc

step "Verify RomM MariaDB sidecar"
kubectl -n media exec deploy/romm -c mariadb -- healthcheck.sh --connect --innodb_initialized
ok "RomM MariaDB healthcheck passed"

step "Verify RomM library mount"
kubectl -n media exec deploy/romm -c romm -- sh -c 'test -d /romm/library && ls /romm/library >/dev/null'
ok "RomM library mount is readable"

step "Verify RomM app container UID/GID"
kubectl -n media exec deploy/romm -c romm -- sh -c '[ "$(id -u):$(id -g)" = "1000:1000" ]'
ok "RomM app container runs as 1000:1000"

step "Verify RomM HTTP service"
# renovate: datasource=docker depName=busybox
kubectl -n media run romm-http-test --restart=Never --rm -i --image=busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616 \
  -- wget -qO- http://romm:8080/ >/dev/null
ok "RomM service responded inside the media namespace"

cat <<'EOF'

Manual validation still required:
- Open https://romm.worm.run.
- Complete the setup wizard.
- Start a library scan and confirm ROMs appear.
- Add metadata-provider credentials with `sops apps/media/romm/romm.sops.yaml` if needed.
- Keep `/romm/library` read-only unless RomM should write imports/uploads to the bulk array.
EOF
