#!/usr/bin/env bash
# Phase 4 secrets - create the SOPS-encrypted Frigate Secret manifest.
#
# Inputs:
#   FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER=...
#   FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD=...
#
# Any additional exported FRIGATE_CAMERA_*_RTSP_USER/PASSWORD pairs are included
# automatically, so future cameras can have separate credentials without changing
# this script.
#
# FRIGATE_JWT_SECRET is generated automatically. Plaintext is written only under a
# temporary directory, then SOPS-encrypted into the Flux target.

# shellcheck source=runbooks/phase4/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl kustomize openssl sops

[ -n "${FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER:-}" ] \
  || die "set FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER"
[ -n "${FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD:-}" ] \
  || die "set FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD"
[ -f "$REPO_ROOT/.sops.yaml" ] || die "missing $REPO_ROOT/.sops.yaml; complete Phase 2 first"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export SOPS_CONFIG="$REPO_ROOT/.sops.yaml"

step "Generate Frigate JWT secret"
openssl rand -hex 32 >"$tmpdir/FRIGATE_JWT_SECRET"
ok "generated FRIGATE_JWT_SECRET"

secret_args=()
secret_keys=()

for key in $(compgen -A variable FRIGATE_CAMERA_ | sort); do
  case "$key" in
    *_RTSP_USER|*_RTSP_PASSWORD)
      [ -n "${!key}" ] || die "$key is set but empty"
      printf '%s' "${!key}" >"$tmpdir/$key"
      secret_args+=(--from-file="$key=$tmpdir/$key")
      secret_keys+=("$key")
      ;;
  esac
done

for key in "${secret_keys[@]}"; do
  case "$key" in
    *_RTSP_USER)
      pair="${key%_RTSP_USER}_RTSP_PASSWORD"
      [ -n "${!pair:-}" ] || die "set $pair to match $key"
      ;;
    *_RTSP_PASSWORD)
      pair="${key%_RTSP_PASSWORD}_RTSP_USER"
      [ -n "${!pair:-}" ] || die "set $pair to match $key"
      ;;
  esac
done

secret_args+=(--from-file="FRIGATE_JWT_SECRET=$tmpdir/FRIGATE_JWT_SECRET")

step "Render plaintext Frigate Secret manifest in a temp dir"
kubectl create secret generic frigate \
  --namespace frigate \
  "${secret_args[@]}" \
  --dry-run=client -o yaml >"$tmpdir/frigate.yaml"

step "Encrypt with SOPS"
sops --encrypt "$tmpdir/frigate.yaml" >"$PHASE4_FRIGATE_SECRET"
ok "encrypted Secret manifest written"

step "Ensure the Secret is included by kustomize"
(
  cd "$PHASE4_FRIGATE_DIR"
  kustomize edit add resource frigate.sops.yaml >/dev/null 2>&1 || true
)
kustomize build "$REPO_ROOT/apps" >/dev/null
ok "Frigate Secret is included in the apps Flux target"
