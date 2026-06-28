#!/usr/bin/env bash
# Phase 4 secrets - merge optional RomM metadata-provider secrets into the
# existing SOPS-encrypted RomM Secret manifest.
#
# Inputs are optional. Set one or more before running:
#   IGDB_CLIENT_ID=...
#   IGDB_CLIENT_SECRET=...
#   SCREENSCRAPER_USER=...
#   SCREENSCRAPER_PASSWORD=...
#   RETROACHIEVEMENTS_API_KEY=...
#   STEAMGRIDDB_API_KEY=...
#
# Plaintext is written only under a temporary directory, then SOPS-encrypted back
# into the Flux target. The existing Secret must be decryptable locally so DB and
# auth keys can be preserved.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools jq kustomize sops yq

[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"
[ -f "$PHASE4_ROMM_SECRET" ] || die "missing $PHASE4_ROMM_SECRET"

provider_keys=(
  IGDB_CLIENT_ID
  IGDB_CLIENT_SECRET
  SCREENSCRAPER_USER
  SCREENSCRAPER_PASSWORD
  RETROACHIEVEMENTS_API_KEY
  STEAMGRIDDB_API_KEY
)

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

jq_filter='.stringData = (.stringData // {})'
jq_args=()
set_count=0

for key in "${provider_keys[@]}"; do
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}" >"$tmpdir/$key"
    jq_args+=(--rawfile "$key" "$tmpdir/$key")
    jq_filter="$jq_filter | .stringData[\"$key\"] = \$$key"
    set_count=$((set_count + 1))
  fi
done

[ "$set_count" -gt 0 ] \
  || die "set at least one RomM provider secret env var before running this script"

step "Decrypt existing RomM Secret manifest"
sops --decrypt --output-type json "$PHASE4_ROMM_SECRET" >"$tmpdir/romm.json" \
  || die "could not decrypt $PHASE4_ROMM_SECRET; set SOPS_AGE_KEY_FILE or another SOPS age identity"
ok "existing RomM Secret decrypted in temp dir"

step "Merge exported provider secrets"
jq "${jq_args[@]}" "$jq_filter" "$tmpdir/romm.json" >"$tmpdir/romm.updated.json"
yq -y '.' "$tmpdir/romm.updated.json" >"$tmpdir/romm.updated.yaml"
ok "merged $set_count provider secret(s)"

step "Encrypt with SOPS"
export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
sops --encrypt "$tmpdir/romm.updated.yaml" >"$PHASE4_ROMM_SECRET"
ok "encrypted RomM Secret manifest written"

step "Verify the Secret is included by kustomize"
kustomize build "$REPO_ROOT/apps" >/dev/null
ok "RomM Secret is included in the apps Flux target"
