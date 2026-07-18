# Monitoring

Phase 5 starts here with backups before the full observability stack.

Committed now:

- `monitoring` namespace.
- Restic NAS backup CronJob for `/opt` app state.
- Enabled weekly Backblaze B2 CronJob for the independent offsite repository.
- Backup script ConfigMap with SQLite, Home Assistant, and RomM hot-backup steps.

The B2 repository initialization, manual backup, repository check, and NAS-independent
restore validation passed on 2026-07-18. Its encrypted Secret is included and the
weekly CronJob is enabled.

Still planned: kube-prometheus-stack, Loki, nut-exporter, ntfy, alert rules, and
backup/health dashboards.
