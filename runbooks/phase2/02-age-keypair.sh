#!/usr/bin/env bash
# Phase 2.2 - generate the SOPS age keypair and enforce the backup checkpoint.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools age-keygen chmod

age_key="$(age_key_file)"

step "Create or reuse age key"
if [ -f "$age_key" ]; then
  warn "$age_key already exists; reusing it"
else
  age-keygen -o "$age_key"
  ok "created $age_key"
fi
# Always enforce 0600 — the reused file may predate this and hold the only
# off-git copy of the decryption key.
chmod 600 "$age_key"

step "Public key"
public_key="$(age_public_key_from_file "$age_key")"
printf '%s\n' "$public_key"

cat <<'EOF'

Back up age.key to the password manager now. This private key is the only secret
that lives outside git and is required for Flux to decrypt SOPS-managed Secrets.
Do not commit age.key.
EOF
confirm "I have backed up age.key to the password manager" || die "backup not confirmed"
ok "age key backup checkpoint confirmed"
