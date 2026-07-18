# Monitoring

Phase 5 starts here with backups before the full observability stack.

Committed now:

- `monitoring` namespace.
- Restic NAS backup CronJob for `/opt` app state.
- Suspended weekly Backblaze B2 CronJob for the independent offsite repository.
- Backup script ConfigMap with SQLite, Home Assistant, and RomM hot-backup steps.

The B2 CronJob remains suspended until its encrypted Secret has been generated and the
manual backup/restore validation in `runbooks/phase5` passes. The generator adds
`restic-b2.sops.yaml` to this kustomization; it is intentionally absent until real B2
credentials are supplied.

Still planned: kube-prometheus-stack, Loki, nut-exporter, ntfy, alert rules, and
backup/health dashboards.
