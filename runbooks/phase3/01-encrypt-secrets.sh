#!/usr/bin/env bash
# Phase 3 secrets - create SOPS-encrypted Secret manifests for Flux.
#
# Inputs:
#   CLOUDDNS_SERVICE_ACCOUNT_JSON=/path/to/gcp-dns-admin-key.json
#   TAILSCALE_OAUTH_CLIENT_ID=...
#   TAILSCALE_OAUTH_CLIENT_SECRET=...
#
# Plaintext is written only under a temporary directory, then SOPS-encrypted into
# infrastructure/configs/secrets/.

# shellcheck source=runbooks/phase3/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl kustomize sops

[ -n "${CLOUDDNS_SERVICE_ACCOUNT_JSON:-}" ] \
  || die "set CLOUDDNS_SERVICE_ACCOUNT_JSON to the CloudDNS service-account JSON file"
[ -f "$CLOUDDNS_SERVICE_ACCOUNT_JSON" ] \
  || die "CloudDNS service-account JSON file not found: $CLOUDDNS_SERVICE_ACCOUNT_JSON"
[ -n "${TAILSCALE_OAUTH_CLIENT_ID:-}" ] \
  || die "set TAILSCALE_OAUTH_CLIENT_ID"
[ -n "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" ] \
  || die "set TAILSCALE_OAUTH_CLIENT_SECRET"
[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"

secret_dir="$REPO_ROOT/infrastructure/configs/secrets"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

step "Render plaintext Secret manifests in a temp dir"
kubectl_create_secret() {
  kubectl create secret generic "$@"
}

kubectl_create_secret clouddns-dns01-solver \
  --namespace cert-manager \
  --from-file=key.json="$CLOUDDNS_SERVICE_ACCOUNT_JSON" \
  --dry-run=client -o yaml >"$tmpdir/clouddns-dns01-solver.yaml"

kubectl_create_secret operator-oauth \
  --namespace tailscale \
  --from-literal=client_id="$TAILSCALE_OAUTH_CLIENT_ID" \
  --from-literal=client_secret="$TAILSCALE_OAUTH_CLIENT_SECRET" \
  --dry-run=client -o yaml >"$tmpdir/tailscale-operator-oauth.yaml"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/clouddns-dns01-solver.yaml" \
  >"$secret_dir/clouddns-dns01-solver.sops.yaml"
sops --encrypt "$tmpdir/tailscale-operator-oauth.yaml" \
  >"$secret_dir/tailscale-operator-oauth.sops.yaml"
ok "encrypted Secret manifests written"

step "Ensure secrets are included by kustomize"
(
  cd "$secret_dir"
  kustomize edit add resource clouddns-dns01-solver.sops.yaml >/dev/null 2>&1 || true
  kustomize edit add resource tailscale-operator-oauth.sops.yaml >/dev/null 2>&1 || true
)
kustomize build "$REPO_ROOT/infrastructure/configs" >/dev/null
ok "encrypted secrets are included in infrastructure/configs"
