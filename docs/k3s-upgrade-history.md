# k3s Upgrade History

This log records attended host maintenance separately from the target pin. A target
being committed does not make it the validated live baseline; update the maintenance,
validation, observation, and cleanup fields only from evidence collected on `minis`.

| Source | Target | Target release date | Maintenance date | Validation | 24-hour observation | Rollback artifacts |
|---|---|---|---|---|---|---|
| `v1.36.2+k3s1` | `v1.36.3+k3s1` | 2026-08-04 | 2026-08-22 17:54Z | Passed initial Phase 2-5 validation; see notes below | In progress; closes after 2026-08-23 17:54Z | Retained through observation |

Initial validation evidence:

- Fresh local snapshot `195b4c6d` and B2 snapshot `59acba9b` independently passed
  backup contract 2 before maintenance. Both contained all eight required application
  SQLite exports, a valid k3s datastore, readable Home Assistant archive, successful
  RomM import, and no server-token artifact.
- The exact k3s binary and kubelet version are `v1.36.3+k3s1`; the API and node are
  Ready. Flux Kustomizations and HelmReleases, SOPS, CRDs, ingress/certificates,
  storage classes/PVCs, direct-array access, GPU/Coral, CoreDNS, and metrics-server
  passed. Intel GPU and TopoLVM components re-registered after the control-plane
  restart and remain healthy.
- Download/VPN, Plex, Seerr, RomM, Frigate, Home Assistant service/integrations, MQTT,
  Z-Wave, Zigbee2MQTT, NUT, blackbox, and Prometheus checks passed. Prometheus reported
  no unhealthy targets or failed blackbox probes; Watchdog remained firing as designed.
- Two `KubeJobFailed` warnings refer only to the failed pre-upgrade backup attempts
  `restic-nas-backup-manual-20260822124115` and
  `restic-nas-backup-manual-20260822124221`. Their logs led to the application SQLite
  busy-timeout fix; the Jobs are retained pending explicit cleanup, and no Job failed
  after the upgrade began.
- A pre-existing host drift was corrected: `dnsmasq` had been disabled since
  2026-08-10 despite the canonical Phase 1 state. Its checked-in configuration and
  syntax passed before the service was enabled; it is active on camera DHCP UDP/67.
- Rollback checkpoint:
  `/var/lib/rancher/k3s-upgrade-checkpoints/20260822T175432Z-v1.36.3+k3s1`.
  Read-only snapshot:
  `/opt/.snapshots/pre-k3s-v1.36.3+k3s1-20260822T175432Z`.

The target release updates Kubernetes to v1.36.3. Its Traefik v40 migration warning
does not affect this cluster because bundled Traefik is disabled and ingress-nginx is
the ingress controller. Source: [official k3s v1.36.3+k3s1 release](https://github.com/k3s-io/k3s/releases/tag/v1.36.3%2Bk3s1).

For each maintenance, record the UTC start/end, reviewed git commit, checkpoint and
snapshot paths, all acceptance-gate results, any new warning events/restarts, rollback
decision, observation close time, and artifact cleanup. Keep tokens and checkpoint
contents out of git.
