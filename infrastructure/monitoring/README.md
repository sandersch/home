# Monitoring

Phase 5 starts here with backups before the full observability stack.

Committed now:

- `monitoring` namespace.
- Restic NAS backup CronJob for `/opt` app state.
- Enabled weekly Backblaze B2 CronJob for the independent offsite repository.
- Backup script ConfigMap with SQLite, Home Assistant, and RomM hot-backup steps.

The B2 repository initialization, manual backup, repository check, and NAS-independent
restore validation passed on 2026-07-18. The nightly NAS and first naturally scheduled
weekly B2 backups both completed successfully on 2026-07-19. Both encrypted Secrets are
included and both CronJobs are enabled.

Still planned: kube-prometheus-stack, Loki with Grafana Alloy for log collection,
nut-exporter, ntfy, alert rules, and backup/health dashboards.
