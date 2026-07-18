#!/usr/bin/env bash
# Phase 5.8 - run the suspended Restic B2 backup CronJob immediately and wait for it.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

assert_phase5_restic_secret_present
assert_phase5_restic_b2_secret_present

job="restic-b2-backup-manual-$(date +%Y%m%d%H%M%S)"

step "Create manual B2 backup job $job from the suspended CronJob"
kubectl -n monitoring create job "$job" --from=cronjob/restic-b2-backup
wait_for_job monitoring "$job" 21600s
