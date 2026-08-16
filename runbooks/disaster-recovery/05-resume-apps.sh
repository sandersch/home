#!/usr/bin/env bash
# Reconcile and validate applications after the apps rebuild guard has been removed
# in its own committed and pushed git change. Monitoring must remain suspended.

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_sudo
[ "$(state_value offline_validation)" = complete ] \
  || die "offline restored-state validation has not passed"
assert_resume_git_posture false true

step "Reconcile the committed apps resume"
flux reconcile kustomization flux-system --with-source
assert_live_guard apps false
assert_live_guard monitoring true
flux reconcile kustomization apps --with-source
kubectl -n flux-system wait kustomization/apps --for=condition=Ready --timeout=15m
ok "apps Kustomization is Ready while monitoring remains suspended"

step "Run automated application recovery gates"
"$REPO_ROOT/runbooks/phase4/00-preflight.sh"
"$REPO_ROOT/runbooks/phase4/02-validate-download-stack.sh"
"$REPO_ROOT/runbooks/phase4/03-validate-plex.sh"
"$REPO_ROOT/runbooks/phase4/04-validate-seerr.sh"
"$REPO_ROOT/runbooks/phase4/05-validate-romm.sh"
"$REPO_ROOT/runbooks/phase4/09-validate-frigate.sh"
"$REPO_ROOT/runbooks/phase4/10-validate-home-assistant.sh"
"$REPO_ROOT/runbooks/phase4/12-validate-mqtt.sh"
"$REPO_ROOT/runbooks/phase4/13-validate-zwave-js.sh"

if sudo test -s /opt/zigbee2mqtt/data/configuration.yaml; then
  "$REPO_ROOT/runbooks/phase4/14-validate-zigbee2mqtt.sh"
else
  warn "the selected snapshot contains no established Zigbee2MQTT state; skipping its live validation"
fi

cat <<'EOF'

Automated recovery checks passed. Before enabling backup schedules, manually verify:
  - Plex libraries, playback, and a forced hardware transcode.
  - One download/import through the VPN stack.
  - Frigate live view plus a new recording and person event.
  - Home Assistant dashboards, automations, MQTT/Frigate, and Z-Wave controls.
  - RomM library contents and metadata.
  - Zigbee devices, if an established Zigbee network was restored.
EOF
confirm "I completed the manual application recovery checks" \
  || die "leave monitoring suspended until manual application validation passes"

set_state_value apps_validation complete
set_state_value apps_validated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok "application recovery gate passed"

cat <<'EOF'

Next, remove spec.suspend from clusters/minis/monitoring.yaml, commit and push that
second change, then run 06-resume-monitoring.sh.
EOF
