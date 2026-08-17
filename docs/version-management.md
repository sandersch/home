# Version Management Plan

This plan makes rebuilds reproducible without turning updates into an unattended
production change. It covers k3s, Helm releases, GitRepository sources, workload and
init-container images, and the images embedded in validation or recovery scripts.

> **Status (2026-08-16): planning complete; implementation pending.** No runtime
> references were changed as part of writing this plan. The live node runs
> `v1.36.2+k3s1`. A read-only inventory confirmed that the currently running
> containers resolve to immutable image digests, but several manifests still request
> mutable tags, so a later pull or rebuild is not yet deterministic.

## Current state

The platform layer is already mostly explicit: Flux-generated controllers, Helm chart
versions, and the Intel GPU plugin Git tag are pinned. The remaining gaps are:

| Surface | Current mutable reference |
|---|---|
| k3s installer | `https://get.k3s.io` with no `INSTALL_K3S_VERSION` |
| Download pod | Gluetun, SABnzbd, qBittorrent, Prowlarr, Radarr, and Sonarr use `latest` |
| Media apps | Plex and Seerr use `latest` |
| Helper/init images | `busybox:1.36` |
| Stateful dependencies | `mariadb:11.4`, `valkey:8`, and `eclipse-mosquitto:2` |

Frigate, Home Assistant, Z-Wave JS UI, RomM, Zigbee2MQTT, the Zigbee2MQTT MQTT
exporter, nut-exporter, and the Restic backup image already name a specific release,
but they are still tag-only references. The recovery and validation scripts that use
MariaDB, Mosquitto, or the Restic image are in scope too; they must not drift from the
production data format or broker version they validate.

## Policy

1. Repo-authored production and recovery container images use
   `repository:release-tag@sha256:digest` wherever the registry publishes a usable
   release tag. The tag keeps the manifest readable; the digest makes the pull
   immutable. If an upstream publishes no suitable release tag, use
   `repository@sha256:digest` and record the upstream application version in a nearby
   comment.
2. `latest`, floating major tags, and floating minor tags are not acceptable final
   desired state. This includes init containers, one-shot validation pods, and restore
   helpers—not only long-running containers.
3. k3s installation sets `INSTALL_K3S_VERSION` explicitly. The first pin is the
   validated live baseline, `v1.36.2+k3s1`; changing that value is a deliberate host
   upgrade, not a side effect of rebuilding.
4. Helm chart versions and GitRepository tags remain exact. Where a chart selects its
   own images, record the rendered image versions during review and verify them after
   reconciliation.
5. Updates are proposed by pull request or a reviewed local commit and are never
   auto-merged. Stateful dependencies, k3s, and Home Assistant require an attended
   maintenance window.
6. The previous tag and digest stay visible in git history. Do not rewrite an existing
   release tag in place merely because its registry digest changed; investigate the
   upstream change and review it as a new update.

## Initial pinning sequence

Implement this in small commits so a failure has a narrow rollback surface:

1. **Inventory and guardrail.** Add a read-only script that lists every repo-authored
   container reference in app, infrastructure, validation, and recovery files. Add a
   CI check that rejects `latest`, tag-only images, floating major/minor tags, and an
   unset `INSTALL_K3S_VERSION`; exclude only Flux's generated bootstrap subtree and
   chart-managed images whose chart version is pinned. Give the check an explicit
   temporary allowlist only while the migration below is in progress.
2. **Resolve the live baseline.** For each running container, capture the requested
   image, Kubernetes `imageID`, embedded application version, and upstream release
   notes. Match each current digest to a readable release tag where one exists. Do not
   select a newer release during this step; the first change should reproduce what is
   running now.
3. **Pin independent helpers first.** Pin BusyBox init containers and the Restic image
   in backup and restore jobs. Run the affected validators before moving to application
   workloads. Keep database and broker helpers for the same commit as their production
   counterpart so compatibility cannot drift.
4. **Pin stateless application edges.** Pin Seerr, then the six-container download
   pod as a single coupled unit. Validate ingress, Mullvad egress, authenticated UI/API
   paths, and a test download/import.
5. **Pin stateful workloads.** Pin Plex, Mosquitto, and RomM's MariaDB/Valkey sidecars
   in separate changes. Update the matching MariaDB/Mosquitto validation and recovery
   helpers in the same commit as the production image. Take the normal `/opt` snapshot
   first and run the application-aware backup/restore checks for database-bearing
   changes.
6. **Pin already-versioned workloads by digest.** Add digests to Frigate, Home
   Assistant, Z-Wave JS UI, RomM, Zigbee2MQTT, its MQTT exporter, nut-exporter, and the
   Restic jobs without changing their release tags. Run each existing Phase 4 or Phase
   5 validator.
7. **Pin k3s last.** Set `INSTALL_K3S_VERSION=v1.36.2+k3s1` in the Phase 2 installer
   and mirror it in the build plan. Exercise the installer guard in a non-destructive
   validation path; do not reinstall the live node just to prove the pin.
8. Remove the migration allowlist. The inventory must then report no mutable runtime
   or recovery references.

## Routine update workflow

Review versions monthly, with an out-of-cycle review for relevant security advisories.
Start manually; a future Renovate configuration may open version PRs, but it must not
auto-merge or reconcile them.

For each update:

1. Read upstream release notes, migration notes, known issues, and rollback limits.
   Confirm Kubernetes compatibility for k3s, controllers, CRDs, and Helm charts.
2. Record the old and proposed tag/digest. Verify the digest directly from the
   publisher's registry or signed release metadata; never copy it from an unrelated
   image mirror.
3. For stateful apps, confirm a current successful Restic backup and take a btrfs
   snapshot of `/opt`. Export or back up application-managed state where the existing
   runbook requires it.
4. Suspend the smallest affected Flux Kustomization when the change is significant,
   commit one compatible workload group, resume/reconcile, and run its existing
   validator. A download-pod update is one group because its six containers share a
   network namespace and lifecycle.
5. Check pod events, restarts, logs, ingress, metrics, and alerts. Observe ordinary
   patch updates for at least 24 hours; use a seven-day gate for k3s, major database
   changes, or changes that affect backup/restore formats.
6. Record the validation date and result in the owning README or runbook. Update the
   tag and digest together; never advance only one half of the reference.

For rollback, revert to the previous tag/digest and reconcile. If an application or
database performed a non-backward-compatible migration, stop it and restore the
pre-update snapshot or application-aware backup instead of starting an older binary
against newer data.

### k3s-specific update gate

Treat a k3s change as host maintenance. Move one supported minor at a time, review the
k3s release notes and Kubernetes version-skew policy, preserve the server token, and
stop k3s long enough to take an access-controlled, internally consistent copy of the
SQLite datastore before the upgrade. Keep that checkpoint outside git. After installing
the exact target version, validate node
readiness, storage, networking, Flux reconciliation, controller CRDs, hardware device
plugins, and representative Phase 4 workloads before closing the maintenance window.

## Completion criteria

- The Phase 2 installer cannot install an unspecified k3s release.
- Repo-authored desired state and executable recovery helpers contain no mutable image
  references; chart-managed images are traceable to an exact chart version.
- Every image reference is readable and immutable, and its upstream release is
  traceable.
- CI detects a newly introduced mutable reference.
- At least one routine application update and its rollback procedure have been
  exercised using this workflow.
