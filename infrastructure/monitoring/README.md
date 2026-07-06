# Monitoring

Phase 5 starts here with backups before the full observability stack.

Committed now:

- `monitoring` namespace.
- Restic NAS backup CronJob for `/opt` app state.
- Backup script ConfigMap with SQLite, Home Assistant, and RomM hot-backup steps.

Still planned: kube-prometheus-stack, Loki, nut-exporter, ntfy, alert rules, and
backup/health dashboards.
