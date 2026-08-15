#!/usr/bin/env bash
# Run the Phase 2 bootstrap steps in dependency order.
# shellcheck source=runbooks/phase2/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEPS=(
  00-preflight.sh
  01-install-k3s.sh
  02-age-keypair.sh
  03-sops-age-secret.sh
  04-sops-config.sh
)

step "Phase 2 - k3s + Flux prerequisites (${#STEPS[@]} steps)"
cat <<'EOF'
This installs k3s, creates the in-cluster SOPS age secret, writes .sops.yaml, and
stops before Flux bootstrap so the repo can be reviewed, committed, and pushed.
EOF
confirm "Run Phase 2 prerequisite steps now?" || die "aborted"

for s in "${STEPS[@]}"; do
  step "=== $s ==="
  bash "$PHASE_DIR/$s"
done

step "Phase 2 prerequisites complete"
cat <<'EOF'
Before bootstrapping Flux:
  1. Review the repo changes, including .sops.yaml and these runbook scripts.
  2. For a rebuild, add spec.suspend: true to clusters/minis/apps.yaml and
     clusters/minis/monitoring.yaml.
  3. Commit and push the changes to the tracked upstream branch.
  4. Confirm age.key remains ignored and uncommitted.

Then run:
  ./05-flux-bootstrap.sh
  ./06-validate-bootstrap.sh

Next phase:
  - Commit and reconcile GitOps-managed infrastructure controllers/configs.
  - Keep apps and monitoring backups suspended until /opt is restored and validated.
  - Do not install controllers imperatively with Helm.
EOF
