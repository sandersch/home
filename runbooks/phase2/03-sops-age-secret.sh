#!/usr/bin/env bash
# Phase 2.3 - store the SOPS age private key in-cluster for Flux decryption.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl base64 cmp mktemp

age_key="$(age_key_file)"
[ -f "$age_key" ] || die "missing $age_key; run 02-age-keypair.sh first"

step "Validate k3s access"
assert_kubectl_ready

step "Create/validate flux-system/sops-age"
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n flux-system get secret sops-age >/dev/null 2>&1; then
  existing_key="$(mktemp)"
  trap 'rm -f "$existing_key"' EXIT
  kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' \
    | base64 -d >"$existing_key"
  if cmp -s "$age_key" "$existing_key"; then
    ok "flux-system/sops-age already matches local age.key"
    exit 0
  fi
  die "flux-system/sops-age differs from local age.key; refusing to overwrite outside an explicit key-rotation runbook"
fi

kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file=age.agekey="$age_key"
ok "flux-system/sops-age created"
