# Monitoring

Phase 5 started with backups and now also contains the first observability slice.

Committed now:

- `base/`: the `monitoring` namespace and SOPS-encrypted Grafana administrator Secret.
- `controllers/`: pinned kube-prometheus-stack Helm source/release. Prometheus keeps
  15 days (up to 16 GB) on a 20 GiB `topolvm-scratch` PVC; Alertmanager and Grafana
  also use small scratch PVCs because their durable configuration lives in git.
- `configs/`: pinned blackbox exporter, HTTPS probes for Home Assistant, Frigate, Plex,
  Seerr, and RomM, an MQTT TCP probe, Flux controller metrics, and operational rules.
- `configs/deadmanssnitch/`: a dormant Alertmanager Watchdog route. Run
  `runbooks/phase5/10-setup-deadmanssnitch.sh` to encrypt the unique check-in URL and
  atomically include the component.
- Restic NAS backup CronJob for `/opt` app state.
- Enabled weekly Backblaze B2 CronJob for the independent offsite repository.
- Backup script ConfigMap with SQLite, Home Assistant, and RomM hot-backup steps.

The B2 repository initialization, manual backup, repository check, and NAS-independent
restore validation passed on 2026-07-18. The nightly NAS and first naturally scheduled
weekly B2 backups both completed successfully on 2026-07-19. Both encrypted Secrets are
included and both CronJobs are enabled. The observability manifests have rendered
successfully locally but are not yet reconciled or live-validated.

Still planned for phase one: nut-exporter, the UPS alert, and live validation. Loki with
Grafana Alloy and ntfy are optional phase-two additions; the phase-one system does not
depend on either centralized logs or a self-hosted notification path.
