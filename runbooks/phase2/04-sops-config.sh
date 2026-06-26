#!/usr/bin/env bash
# Phase 2.4 - write the repo SOPS config using the generated age public key.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools age-keygen

age_key="$(age_key_file)"
sops_config="$(sops_config_file)"
[ -f "$age_key" ] || die "missing $age_key; run 02-age-keypair.sh first"

public_key="$(age_public_key_from_file "$age_key")"
expected="$(mktemp)"
trap 'rm -f "$expected"' EXIT
cat >"$expected" <<EOF
creation_rules:
  - path_regex: .*\\.yaml
    encrypted_regex: ^(data|stringData)$
    age: $public_key
EOF

step "Write .sops.yaml"
if [ -f "$sops_config" ]; then
  if cmp -s "$expected" "$sops_config"; then
    ok "$sops_config already up to date"
  else
    warn "$sops_config already exists and differs"
    diff -u "$sops_config" "$expected" || true
    confirm "Replace $sops_config with the Phase 2 SOPS config?" || die "aborted"
    install -m 0644 "$expected" "$sops_config"
    ok "updated $sops_config"
  fi
else
  install -m 0644 "$expected" "$sops_config"
  ok "created $sops_config"
fi
