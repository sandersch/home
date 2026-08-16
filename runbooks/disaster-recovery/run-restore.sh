#!/usr/bin/env bash
# Execute the destructive, offline half of full-state disaster recovery. Snapshot
# listing remains a separate explicit selection step.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=runbooks/disaster-recovery/lib.sh
source "$script_dir/lib.sh"
require_recovery_source
require_recovery_snapshot

"$script_dir/00-preflight.sh"
"$script_dir/02-restore-opt.sh"
"$script_dir/03-restore-romm.sh"
"$script_dir/04-validate-restored-state.sh"
