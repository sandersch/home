# Version Management

This workflow makes rebuilds deterministic without turning dependency discovery into
an unattended production deployment. It covers repo-authored workload, init,
validation, recovery, and container-build images. Helm-managed images, generated Flux
manifests, GitHub Actions versions, and k3s are outside this container-image slice.

> **Status (2026-08-22): container-image slice and exact k3s installer pin implemented.**
> The Phase 2 installer passes the validated live baseline `v1.36.2+k3s1` through
> `INSTALL_K3S_VERSION`, and its active-server guard plus bootstrap validator reject
> any installed version that does not match the pin.

## Immutable baseline

The initial pins were derived read-only from Ready containers in the active
ReplicaSets. Requested images and Kubernetes `imageID` values were captured, stale
historical pods were ignored, and publisher metadata was used to recover exact release
tags. For multi-architecture images, the publisher's index digest is pinned after its
Linux/amd64 child was checked against the live image.

Every normal reference is `repository:exact-release@sha256:digest`. Gluetun is the one
documented digest-only exception: the deployed `latest` commit had no exact upstream
release tag, so its upstream revision and build date are adjacent to its publisher
digest. MariaDB and Valkey keep readable application versions beside the live index
digests. Their publisher tags were rebuilt after deployment; retaining the live digest
is what preserves the deployed bytes, and Renovate may propose the publisher's rebuild
as an attended digest update.

Production and recovery/validation references for BusyBox, MariaDB, Mosquitto, the
custom Restic image, and every other repeated repository must remain identical. This
is enforced across the complete inventory rather than maintained as a hand-written
list.

## Inventory and CI guardrail

Run the read-only inventory or strict check from the repository root:

```bash
runbooks/version-management/image_policy.py inventory
runbooks/version-management/image_policy.py check
runbooks/version-management/test-image-policy.sh
```

The scanner covers `apps/`, `infrastructure/`, `containers/`, and shell runbooks. It
excludes SOPS-encrypted content, documentation, its own fixtures during a real scan,
chart-managed images, and generated Flux bootstrap manifests. Output records file,
line, source type, normalized repository, tag, and digest. `$RECOVERY_IMAGE` is the
only approved indirection and is resolved to its canonical definition.

Strict mode rejects `latest` and channel tags, floating major/minor tags, tag-only
references, malformed digests, digest-only references without an adjacent upstream
version, unannotated shell references, unsupported indirection, and coupled-reference
drift. Fixtures prove accepted exact pins and rejection of each prohibited form. The
completed migration has no allowlist.

`.github/workflows/image-policy.yaml` runs on every pull request and push to `main`.
It executes the fixtures and inventory, runs `bash -n` and ShellCheck on changed shell
scripts, renders the application and monitoring Kustomizations, and strictly validates
the Renovate configuration. After its first successful repository run, make
`image-policy / validate` a required `main` branch check.

## Renovate proposal policy

The hosted Renovate GitHub App is the update proposer. Restrict its installation to
the private `sandersch/home` repository, then review and merge its onboarding PR.
Flux watches only `main`, so an open Renovate PR cannot change the cluster.

`renovate.json5` enables only the Kubernetes, Dockerfile, and annotated-shell regex
managers. It explicitly scans repo-authored Kubernetes paths, manages the custom
Restic Containerfile base, pins and updates digests, and consolidates duplicate
manifest/shell occurrences into one logical dependency. Standard shell annotations
have this form:

```bash
# renovate: datasource=docker depName=busybox
```

Renovate never auto-merges, allows at most five concurrent PRs, and creates routine
PRs Sunday 00:00–05:59 America/Chicago. Major versions require Dependency Dashboard
approval. Gluetun, SABnzbd, qBittorrent, Prowlarr, Radarr, and Sonarr are grouped into
one download-stack PR; unrelated applications remain separate. Updates for
`ghcr.io/sandersch/restic-backup` itself are disabled because its attended workflow
owns that artifact, while `restic/restic` base updates remain enabled.

Every image PR warns that merge changes production through Flux and links to the Phase
4/5 validators and rollback procedure. Before accepting normal PRs, confirm the
Dependency Dashboard finds each external dependency once logically, keeps the download
stack grouped, and gates majors.

## Attended custom Restic image

`containers/restic-backup/VERSION` is the canonical unique release/revision, such as
`0.19.0-1`. The Containerfile pins `restic/restic` by exact release and digest.

The `restic-backup-image` workflow builds pull requests without publishing. To publish
a reviewed change:

1. Bump the version/revision on the reviewed branch; never reuse a tag for changed
   build inputs.
2. Manually dispatch the workflow for that branch. It validates and builds first,
   refuses an already-existing GHCR tag, and then publishes.
3. Copy the reported publisher digest into every CronJob and recovery helper on the
   same branch before merge.
4. Rerun image-policy CI. It enforces version-file/tag consistency and identical custom
   image references.

## Routine update and rollback workflow

For each proposed update:

1. Read release, migration, known-issue, and rollback notes. Verify the changed tag and
   digest against the publisher rather than a mirror.
2. For stateful or critical changes, confirm a fresh Restic backup and take the
   required `/opt` btrfs snapshot. Suspend the smallest affected Flux Kustomization.
3. Review and merge one compatible workload group. Resume/reconcile Flux and run the
   owning Phase 4 or Phase 5 validator. Check events, restarts, logs, ingress, metrics,
   and alerts.
4. Observe ordinary changes for 24 hours. Keep the existing seven-day gate for major
   databases or any format-affecting change.

Rollback by reverting the Git commit and reconciling. If an application migrated data
incompatibly, stop it and restore the pre-update snapshot or application-aware backup
instead of starting the older binary against newer data.

## Remaining rollout and acceptance work

- Merge the guardrail and require `image-policy / validate` on `main`.
- Install Renovate for `sandersch/home` only, merge onboarding, and inspect its dry-run
  dependency report and grouping.
- Exercise one low-risk Seerr update: attended merge, Flux validation, Git revert and
  rollback validation, reapply, then observe for 24 hours.

### k3s-specific update gate

Treat every k3s change as host maintenance. Move one supported minor at a time, review
k3s release notes and Kubernetes version skew, preserve the server token, and take an
access-controlled consistent copy of the SQLite datastore while k3s is stopped. Keep
that checkpoint outside git. After installing the exact target, validate node readiness,
storage, networking, Flux, controller CRDs, device plugins, and representative Phase 4
workloads before closing the maintenance window.
