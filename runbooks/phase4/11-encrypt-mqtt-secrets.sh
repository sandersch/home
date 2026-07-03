#!/usr/bin/env bash
# Phase 4 secrets - create SOPS-encrypted MQTT credentials for Mosquitto, Frigate,
# and Home Assistant.
#
# Optional inputs:
#   MOSQUITTO_FRIGATE_USER=frigate
#   MOSQUITTO_FRIGATE_PASSWORD=...
#   MOSQUITTO_HOME_ASSISTANT_USER=home-assistant
#   MOSQUITTO_HOME_ASSISTANT_PASSWORD=...
#
# Missing passwords are generated. Plaintext is written only under a temporary
# directory, then SOPS-encrypted into the Flux targets. To configure Home Assistant,
# decrypt apps/mqtt/mosquitto-auth.sops.yaml locally with sops and use the
# MOSQUITTO_HOME_ASSISTANT_* values in the MQTT integration UI.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl kustomize openssl sops

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"

MOSQUITTO_FRIGATE_USER="${MOSQUITTO_FRIGATE_USER:-frigate}"
MOSQUITTO_HOME_ASSISTANT_USER="${MOSQUITTO_HOME_ASSISTANT_USER:-home-assistant}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ -z "${MOSQUITTO_FRIGATE_PASSWORD:-}" ]; then
  MOSQUITTO_FRIGATE_PASSWORD="$(openssl rand -base64 32)"
  export MOSQUITTO_FRIGATE_PASSWORD
fi

if [ -z "${MOSQUITTO_HOME_ASSISTANT_PASSWORD:-}" ]; then
  MOSQUITTO_HOME_ASSISTANT_PASSWORD="$(openssl rand -base64 32)"
  export MOSQUITTO_HOME_ASSISTANT_PASSWORD
fi

for key in \
  MOSQUITTO_FRIGATE_USER \
  MOSQUITTO_FRIGATE_PASSWORD \
  MOSQUITTO_HOME_ASSISTANT_USER \
  MOSQUITTO_HOME_ASSISTANT_PASSWORD; do
  [ -n "${!key}" ] || die "$key is empty"
  printf '%s' "${!key}" >"$tmpdir/$key"
done

step "Render plaintext Mosquitto Secret manifest in a temp dir"
kubectl create secret generic mosquitto-auth \
  --namespace mqtt \
  --from-file="MOSQUITTO_FRIGATE_USER=$tmpdir/MOSQUITTO_FRIGATE_USER" \
  --from-file="MOSQUITTO_FRIGATE_PASSWORD=$tmpdir/MOSQUITTO_FRIGATE_PASSWORD" \
  --from-file="MOSQUITTO_HOME_ASSISTANT_USER=$tmpdir/MOSQUITTO_HOME_ASSISTANT_USER" \
  --from-file="MOSQUITTO_HOME_ASSISTANT_PASSWORD=$tmpdir/MOSQUITTO_HOME_ASSISTANT_PASSWORD" \
  --dry-run=client -o yaml >"$tmpdir/mosquitto-auth.yaml"

step "Render plaintext Frigate MQTT Secret manifest in a temp dir"
kubectl create secret generic frigate-mqtt \
  --namespace frigate \
  --from-file="FRIGATE_MQTT_USER=$tmpdir/MOSQUITTO_FRIGATE_USER" \
  --from-file="FRIGATE_MQTT_PASSWORD=$tmpdir/MOSQUITTO_FRIGATE_PASSWORD" \
  --dry-run=client -o yaml >"$tmpdir/frigate-mqtt.yaml"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/mosquitto-auth.yaml" >"$PHASE4_MQTT_SECRET"
sops --encrypt "$tmpdir/frigate-mqtt.yaml" >"$PHASE4_FRIGATE_MQTT_SECRET"
ok "encrypted Mosquitto and Frigate MQTT Secret manifests written"

step "Ensure the Secret is included by kustomize"
(
  cd "$PHASE4_MQTT_DIR"
  kustomize edit add resource mosquitto-auth.sops.yaml >/dev/null 2>&1 || true
)
(
  cd "$PHASE4_FRIGATE_DIR"
  kustomize edit add resource frigate-mqtt.sops.yaml >/dev/null 2>&1 || true
)
kustomize build "$REPO_ROOT/apps" >/dev/null
ok "MQTT Secrets are included in the apps Flux target"

cat <<'EOF'

Next:
- Run `sops apps/mqtt/mosquitto-auth.sops.yaml` locally when you need the Home
  Assistant MQTT username/password for the UI.
EOF
