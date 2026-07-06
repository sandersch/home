#!/usr/bin/env bash
# Phase 5.4 - run the Restic NAS backup CronJob immediately and wait for it.
# shellcheck source=runbooks/phase5/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl

assert_phase5_restic_secret_present

job="restic-nas-backup-manual-$(date +%Y%m%d%H%M%S)"

step "Create manual backup job $job from the CronJob"
kubectl -n monitoring create job "$job" --from=cronjob/restic-nas-backup
wait_for_job monitoring "$job" 3600s
