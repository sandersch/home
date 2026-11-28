#!/usr/bin/env bash
# Attended one-time migration for switching an existing zigbee2mqtt-mqtt-exporter
# Deployment from the API-defaulted RollingUpdate strategy to Recreate.
#
# Flux's kustomize-controller uses Server-Side Apply and preserves the unowned
# API-defaulted spec.strategy.rollingUpdate block when the manifest omits it,
# causing Kubernetes validation to reject type: Recreate. Run this with an admin
# kubeconfig before Flux reconciles the apps Kustomization; it clears
# rollingUpdate and sets Recreate in a single merge patch and is a no-op on
# fresh or already-migrated clusters.

# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kubectl

step "Verify the kubeconfig can inspect and patch zigbee2mqtt Deployments"
[ "$(kubectl auth can-i get deployments.apps -n zigbee2mqtt)" = "yes" ] \
  || die "current kubeconfig cannot read deployments in zigbee2mqtt; switch explicitly to homelab-admin"
[ "$(kubectl auth can-i patch deployments.apps -n zigbee2mqtt)" = "yes" ] \
  || die "current kubeconfig cannot patch deployments in zigbee2mqtt; switch explicitly to homelab-admin"
ok "current kubeconfig can inspect and patch deployments in zigbee2mqtt"

step "Inspect live deploy/zigbee2mqtt-mqtt-exporter strategy"
if ! deployment_json="$(
  kubectl -n zigbee2mqtt get deploy zigbee2mqtt-mqtt-exporter -o json --ignore-not-found
)"; then
  die "failed to query deploy/zigbee2mqtt-mqtt-exporter"
fi

if [ -z "$deployment_json" ]; then
  ok "deploy/zigbee2mqtt-mqtt-exporter does not exist yet; fresh installs need no migration"
  exit 0
fi

if jq -e '
  .spec.strategy.type == "Recreate" and
  .spec.strategy.rollingUpdate == null
' >/dev/null <<<"$deployment_json"; then
  ok "deploy/zigbee2mqtt-mqtt-exporter already uses Recreate without rollingUpdate"
  exit 0
fi

step "Clear rollingUpdate and set Recreate in one merge patch"
kubectl -n zigbee2mqtt patch deploy zigbee2mqtt-mqtt-exporter --type=merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

deployment_json="$(kubectl -n zigbee2mqtt get deploy zigbee2mqtt-mqtt-exporter -o json)"
jq -e '
  .spec.strategy.type == "Recreate" and
  .spec.strategy.rollingUpdate == null
' >/dev/null <<<"$deployment_json" \
  || die "deploy/zigbee2mqtt-mqtt-exporter did not converge to Recreate without rollingUpdate"

kubectl -n zigbee2mqtt rollout status deploy/zigbee2mqtt-mqtt-exporter --timeout=300s
ok "deploy/zigbee2mqtt-mqtt-exporter now uses Recreate without rollingUpdate; ready for Flux apps reconciliation"
