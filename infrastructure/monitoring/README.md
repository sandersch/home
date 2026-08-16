# Monitoring

Phase 5 started with backups and now also contains the first observability slice.

Committed now:

- `base/`: the `monitoring` namespace and SOPS-encrypted Grafana administrator Secret.
- `controllers/`: pinned kube-prometheus-stack Helm source/release. Prometheus keeps
  15 days (up to 16 GB) on a 20 GiB `topolvm-scratch` PVC; Alertmanager and Grafana
  also use small scratch PVCs because their durable configuration lives in git.
- `configs/`: pinned blackbox exporter, HTTPS probes for Home Assistant, Frigate, Plex,
  Seerr, and RomM, an MQTT TCP probe, Flux controller metrics, a hardened nut-exporter
  workload and ServiceMonitor, the CP1500 Grafana dashboard, and operational rules.
- `configs/deadmanssnitch/`: an opt-in Alertmanager Watchdog route, currently active.
  Run
  `runbooks/phase5/10-setup-deadmanssnitch.sh` to encrypt the unique check-in URL and
  atomically include the component.
- `configs/pushover/`: the active actionable-alert route with explicit normal/high
  firing priorities and quiet recovery notifications. Run
  `runbooks/phase5/11-setup-pushover.sh` to encrypt the recipient/application keys and
  atomically include the component.
- Restic direct-array backup CronJob for `/opt` app state (the `restic-nas-*` object
  names are retained as stable legacy identifiers).
- Enabled weekly Backblaze B2 CronJob for the independent offsite repository.
- Backup script ConfigMap with a versioned required-export contract. It blocks Restic
  unless the mandatory Plex, Frigate, Prowlarr, Radarr, Sonarr, Seerr, Home Assistant,
  and RomM application-aware exports are fresh and valid.

The B2 repository initialization, manual backup, repository check, and local-volume-independent
restore validation passed on 2026-07-18. The nightly local and first naturally scheduled
weekly B2 backups both completed successfully on 2026-07-19. Those results predate
required-export contract version 1; fresh local and B2 validation of the stricter
contract is pending. Both encrypted Secrets are included and both CronJobs are enabled.
The observability stack passed live validation
on 2026-07-20: Flux and Helm were ready, all scrape targets and blackbox probes were
healthy, Grafana worked through its HTTPS ingress, the rules loaded without errors,
and the Alertmanager Watchdog route delivered successfully to a healthy Dead Man's
Snitch check. The hosted Pushover route subsequently passed its synthetic drill:
warning and critical firing notifications and their resolved notifications reached the
iPhone.

The nut-exporter workload, CP1500 dashboard, and one-minute critical on-battery alert
were added on 2026-07-22 and passed live validation on 2026-07-25. Validation covered
the exporter endpoint and UPS telemetry, Prometheus target and rule health, Grafana
dashboard provisioning, and the operator-gated physical mains-loss drill. The drill
produced the expected critical Pushover firing notification and quiet recovery
notification. Resource tuning remains after roughly one week of real metrics. Loki
with Grafana Alloy is an optional phase-two addition; notification delivery does not
require another cluster workload.
