# Phase 2 - k3s + Flux bootstrap prerequisites (runbook)

Scripts for [build-plan.md Phase 2](../../docs/build-plan.md#phase-2--k3s--flux-bootstrap-prerequisites-).
They run on `minis` after Phase 0 and Phase 1 host setup.

This phase is intentionally small. The only imperative cluster writes are the k3s
install, the `flux-system/sops-age` Secret, and `flux bootstrap`. Everything else
that changes Kubernetes state belongs in git and is reconciled by Flux in Phase 3.

## Prerequisites

- Phase 0 is complete, including hostname `minis`, swap disabled, base packages,
  and readable `/mnt/media`.
- Phase 1 host-side camera isolation is applied.
- This repo is checked out on `minis`.
- The `flux` CLI is installed on `minis`:
  ```bash
  curl -s https://fluxcd.io/install.sh | sudo bash
  flux version --client
  ```
  `flux bootstrap github` uses `GITHUB_TOKEN`; export it before running
  `05-flux-bootstrap.sh`.
- GitHub owner/repository/branch are `sandersch/home` on `main`, matching the build
  plan.
- For a rebuild of this populated repo, restore the existing `age.key` from the
  password manager. Do not generate a replacement key; it cannot decrypt the committed
  SOPS Secrets.
- Before `05-flux-bootstrap.sh`, add `spec.suspend: true` to both
  `clusters/minis/apps.yaml` and `clusters/minis/monitoring.yaml`, then commit and push
  that rebuild guard. Do this only after the old cluster is offline or after
  deliberately accepting paused Flux reconciliation there.

## Order

Run scripts in numeric order, or run `./run-all.sh` for steps 00-04. Run validation
after bootstrap has settled.

| Script | Build-plan step | What it does | Interactive? |
|---|---|---|---|
| `00-preflight.sh` | - | Read-only sanity checks for host, repo, and tool posture | no |
| `01-install-k3s.sh` | 2.1 | Bootstrap-only install of exact release `v1.36.3+k3s1` with Traefik and servicelb disabled and node name `minis`, then copies kubeconfig to the runbook user's `~/.kube/config` as `0600`; an active server must already match the pin and is never upgraded here | install prompt; restart prompt when changing an active server |
| `02-age-keypair.sh` | 2.2 | Creates a key only for an initial build; on a rebuild, requires the restored `age.key` to match the committed SOPS recipient | backup prompt |
| `03-sops-age-secret.sh` | 2.3 | Creates or validates `flux-system/sops-age` from `age.key` | no |
| `04-sops-config.sh` | 2.4 | Writes `.sops.yaml` using the generated public key | overwrite prompt if needed |
| `05-flux-bootstrap.sh` | 2.5 | Verifies the committed apps/backup suspend guards, then runs `flux bootstrap github` for the private repo | bootstrap prompt |
| `06-validate-bootstrap.sh` | - | Validates node readiness, Flux manifests, SOPS secret, and Flux health | no |
| `07-upgrade-k3s.sh` | maintenance | Performs the guarded, checkpointed upgrade to the exact `K3S_VERSION` pin; an already-current node exits without changes | four confirmations |
| `08-rollback-k3s.sh CHECKPOINT` | maintenance | Validates a root-only checkpoint, preserves failed post-upgrade state, and restores the recorded source version | rollback prompt |

## Notes

- `age.key` is intentionally local-only. Back it up to the password manager and do
  not commit it.
- `host/minis/etc/rancher/k3s/config.yaml` bounds cluster-wide terminal Pod objects
  at 20 via `terminated-pod-gc-threshold`. PodGC removes the oldest `Failed` or
  `Succeeded` Pods after the total exceeds that threshold, so their old logs are not
  retained indefinitely.
- `K3S_VERSION` in `lib.sh` is the canonical exact installer and validation pin.
  `01-install-k3s.sh` passes it to the upstream installer as
  `INSTALL_K3S_VERSION`; both the installer guard and `06-validate-bootstrap.sh`
  reject an active server on a different release. Updating this value is host
  maintenance and must follow the gate in `docs/version-management.md`.
- `01-install-k3s.sh` is bootstrap-only. If its active-version guard fails, use
  `07-upgrade-k3s.sh`; do not use the bootstrap installer to mutate a live server.
- `.sops.yaml` contains only the public age recipient and is committed normally.
- `run-all.sh` stops after `.sops.yaml` is written. Review, commit, and push the
  repo changes and the two rebuild suspend guards before running
  `05-flux-bootstrap.sh` manually.
- `05-flux-bootstrap.sh` requires the repo to be clean and up to date with its
  upstream. Commit and push `.sops.yaml` before running it; ignored `age.key` is
  allowed to remain local.
- `flux bootstrap` owns `clusters/minis/flux-system`; do not hand-edit that subtree.
- The existing Flux skeleton outside `flux-system` stays repo-owned and is reconciled
  after bootstrap.
- A suspended Flux Kustomization prevents new reconciliation; it does not stop
  workloads that already exist. A fresh rebuild must show no app pods and no Restic
  CronJobs before `/opt` is restored.
- Phase 3 is the normal Flux-managed cluster infrastructure phase. Do not use
  imperative Helm installs for MetalLB, ingress-nginx, cert-manager, Tailscale, or
  TopoLVM.

## Attended k3s upgrade

The current reviewed transition is `v1.36.2+k3s1` to `v1.36.3+k3s1`. The target was
released on 2026-08-04. Its bundled Traefik v40 warning is out of path because this
cluster disables bundled Traefik and uses ingress-nginx. Do not drain the single node
or suspend Flux for this patch: k3s leaves existing workload containers running while
its control plane restarts.

Land and push the target-pin/runbook commit first, then pull that exact reviewed commit
on `minis`. Before running the upgrade, complete both backup and restore gates:

```bash
./runbooks/phase5/04-run-manual-backup.sh
./runbooks/phase5/05-validate-restore.sh
./runbooks/phase5/08-run-manual-b2-backup.sh
./runbooks/phase5/09-validate-b2-restore.sh
```

Record the maintenance start time and pre-change state. The historical failed Plex and
Frigate Pods are known baseline noise; reject new failed Pods, warning events, or
restart growth after the recorded timestamp.

```bash
date -u
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get pvc -A
kubectl get events -A --sort-by=.lastTimestamp
flux get kustomizations -A
flux get helmreleases -A
kubectl get prometheusrules -A
kubectl get alerts -A 2>/dev/null || true

./runbooks/phase2/07-upgrade-k3s.sh
```

The script requires hostname `minis`, non-root sudo use, a clean branch exactly even
with its upstream, active/healthy k3s and Flux, canonical server config, a valid SQLite
`kine` datastore, the server token, and a stable forward move of at most one minor. It
downloads the official installer before downtime, creates a read-only `/opt` snapshot,
then stops k3s to create a root-owned `0700` checkpoint under
`/var/lib/rancher/k3s-upgrade-checkpoints`. The checkpoint contains the prior binary,
systemd unit/environment, config, complete SQLite database directory, matching token,
metadata, and checksums. Any failure prints the exact evidence and rollback paths.

After the API returns, run every applicable acceptance gate:

```bash
./runbooks/phase2/06-validate-bootstrap.sh
./runbooks/phase3/03-validation-gate.sh
./runbooks/phase4/02-validate-download-stack.sh
./runbooks/phase4/03-validate-plex.sh
./runbooks/phase4/04-validate-seerr.sh
./runbooks/phase4/05-validate-romm.sh
./runbooks/phase4/09-validate-frigate.sh
./runbooks/phase4/10-validate-home-assistant.sh
./runbooks/phase4/12-validate-mqtt.sh
./runbooks/phase4/13-validate-zwave-js.sh
./runbooks/phase4/14-validate-zigbee2mqtt.sh
./runbooks/phase5/13-validate-nut-exporter.sh
./runbooks/phase5/15-validate-zigbee2mqtt-monitoring.sh
```

Also verify CoreDNS and metrics-server, every Flux Kustomization and HelmRelease, PVC
bindings, ingress endpoints, blackbox probes, Prometheus targets, active alerts,
restart deltas, and warning events. Do not perform a physical UPS mains-loss drill for
this maintenance. Record the results in
[`docs/k3s-upgrade-history.md`](../../docs/k3s-upgrade-history.md), then observe for 24
hours: application availability, Frigate recording/detection, home-automation traffic,
Plex playback, scheduled backups, resource use, events, Pushover, and Watchdog.

Roll back immediately for datastore corruption, persistent control-plane instability,
storage/device-plugin regression, or critical workload failure:

```bash
./runbooks/phase2/08-rollback-k3s.sh \
  /var/lib/rancher/k3s-upgrade-checkpoints/20260822T000000Z-v1.36.3+k3s1
```

Only after the 24-hour observation is closed, remove the exact token-bearing checkpoint
and temporary snapshot paths printed by the upgrade. Verify each literal path first;
do not use globs.

```bash
sudo btrfs subvolume show /opt/.snapshots/pre-k3s-v1.36.3+k3s1-20260822T000000Z
sudo stat /var/lib/rancher/k3s-upgrade-checkpoints/20260822T000000Z-v1.36.3+k3s1
sudo btrfs subvolume delete /opt/.snapshots/pre-k3s-v1.36.3+k3s1-20260822T000000Z
sudo rm -rf /var/lib/rancher/k3s-upgrade-checkpoints/20260822T000000Z-v1.36.3+k3s1
```

The timestamps above are examples; replace them with the two exact paths printed by
the upgrade.
