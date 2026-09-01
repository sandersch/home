# Monitoring

Phase 5 started with backups and now also contains the first observability slice.

Committed now:

- `base/`: the `monitoring` namespace and SOPS-encrypted Grafana administrator Secret.
- `controllers/`: pinned kube-prometheus-stack Helm source/release. Prometheus keeps
  15 days (up to 16 GB) on a 20 GiB `topolvm-scratch` PVC; Alertmanager and Grafana
  also use small scratch PVCs because their durable configuration lives in git.
- `configs/`: pinned blackbox exporter, HTTPS probes for Home Assistant, Frigate,
  Zigbee2MQTT, Plex, Seerr, and RomM, MQTT-broker and SLZB Zigbee-coordinator TCP
  probes, Flux controller metrics, a Zigbee2MQTT MQTT-health ServiceMonitor, a
  hardened nut-exporter workload and ServiceMonitor, the CP1500 Grafana dashboard,
  and operational rules.
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
  unless the mandatory Plex, Frigate, Radarr, Sonarr, Seerr, Home Assistant, and RomM
  application-aware exports are fresh and valid, and unless a validated online backup
  of the live k3s SQLite datastore is present. Prowlarr is a best-effort discovered
  export with bounded retries. The k3s server token is not mounted or backed up.

The B2 repository initialization, manual backup, repository check, and local-volume-independent
restore validation passed on 2026-07-18. The nightly local and first naturally scheduled
weekly B2 backups both completed successfully on 2026-07-19. Backup-contract version
3 passed fresh local and B2 backup/restore validation on 2026-08-22. Local snapshot
`731326fa` and B2 snapshot `fe10c1ff` validated the k3s SQLite artifact, all eight
then-mandatory application SQLite exports, the Home Assistant archive, a 32-table
RomM import, and the absence of a server-token artifact. Both encrypted Secrets are
included and both CronJobs are enabled.
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
notification. The Zigbee2MQTT critical HTTPS and SLZB coordinator TCP probes plus the
MQTT-native bridge-health path passed live validation on 2026-08-16: the exporter
target was healthy, the retained bridge state was online, MQTT was connected,
one-minute health data was fresh, both blackbox paths succeeded, and the bridge-health
and shared endpoint rules were healthy with no active Zigbee2MQTT alert. Resource
tuning changes for the standard-tier media workloads were deployed on 2026-08-13;
their seven-day observation gate remains open, and monitoring-specific tuning can
follow from the same audit data. Loki with Grafana Alloy is an optional phase-two
addition; notification delivery does not require another cluster workload.
