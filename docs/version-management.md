# Version Management

This workflow makes rebuilds deterministic without turning dependency discovery into
an unattended production deployment. It covers repo-authored workload, init,
validation, recovery, and container-build images. Helm chart versions are proposed
through the Flux manager; Helm-managed images, generated Flux manifests, GitHub
Actions versions, and k3s remain outside this container-image slice.

> **Status (2026-08-23): container-image slice and attended k3s lifecycle implemented.**
> The Phase 2 target pin and validated live baseline are `v1.36.3+k3s1`. Attended
> maintenance and initial validation completed on 2026-08-22. The 24-hour observation
> passed and the temporary rollback artifacts were removed on 2026-08-23, as recorded
> in the [upgrade history](./k3s-upgrade-history.md). The bootstrap installer rejects
> active-version drift and directs operators to the guarded upgrade runbook.

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
The `checks` job always executes the image fixtures/inventory, k3s safety tests,
backup contract/configuration regressions, `bash -n` and ShellCheck on changed shell
scripts, and application/monitoring Kustomization renders. Expensive alert and
repository integrations then run in parallel: alert rules, offline SSD/appstate,
legacy archive recovery, and workstation/append-only server coverage. Every existing
suite is retained, including real Restic round trips and isolated MariaDB imports.

On PRs only, `runbooks/version-management/ci-integration-scope.py` skips the expensive
integrations when **all** changes are known unrelated paths: Markdown under `docs/`,
root `AGENTS.md`/`README.md`, `renovate.json5`, or apps outside `apps/media/romm/`.
RomM is deliberately included because the appstate test uses its pinned database image.
Unknown paths, missing/failed diffs, CI changes, and every push to `main` run the full
suite. Renames consider both paths; selection uses the entire PR merge diff. Tests
guard this selection policy. New integration dependencies must update it if they
fall under a currently excluded path.

Keep `image-policy / validate` as the required `main` branch check. It now aggregates
the jobs and explicitly rejects failed, cancelled, or unexpectedly skipped suites.
Superseded runs of the same PR are cancelled; separate PRs and main pushes retain
independent runs. Based on the 2026-10-06 baseline, parallelism should reduce full
runs from roughly 5–7 minutes to roughly 3 minutes plus runner queueing, while
unrelated PRs need only the quick checks and final gate. Confirm actual timings
after this workflow runs on GitHub.

`.github/workflows/renovate-config.yaml` validates the Renovate configuration,
running only when `renovate.json5` or that workflow (which pins the validator version)
changes. The validator pin carries a `# renovate: datasource=npm depName=renovate`
annotation, and a workflow regex manager keeps it current so the check accepts
config forms that hosted Renovate's own migrations produce. Validator updates merge
automatically; see the proposal policy below.

The check deliberately omits `--strict`. Strict mode fails on any pending config
migration, so a newer validator rejects the old config format while the old validator
rejects Renovate's migrated format, and neither PR can pass alone. Without it, real
validation errors still fail the check, and a pending migration produces a
`Config migration necessary` warning annotation instead. When Renovate changes its
config format:

1. Renovate's validator bump passes (with the migration warning) and auto-merges.
2. Renovate's config migration PR then passes against the new validator; review and
   merge it.

If the migration PR arrives before the validator bump has merged, it fails until the
bump lands. Then tick the rebase checkbox on the migration PR; re-running the failed
job reuses the old merge commit and fails again.

## Renovate proposal policy

The hosted Renovate GitHub App is the update proposer. Restrict its installation to
the private `sandersch/home` repository, then review and merge its onboarding PR.
Flux watches only `main`, so an open Renovate PR cannot change the cluster.

`renovate.json5` enables the Kubernetes, Flux, Dockerfile, and annotated-shell regex
managers. It explicitly scans repo-authored Kubernetes and Flux paths, manages Helm
chart versions in Flux `HelmRelease` resources from their `HelmRepository` sources,
manages the custom Restic Containerfile base, pins and updates supported image
digests, and consolidates duplicate
manifest/shell occurrences into one logical dependency. Standard shell annotations
have this form:

Flux-managed chart and source references are intentionally version/tag managed without
digest pinning: Flux `HelmRelease` and `GitRepository` resources do not expose a
digest-pinnable field for these dependencies. The package rule in `renovate.json5`
skips only unsupported Flux `pinDigest` updates; container image digest pinning remains
enabled for the Kubernetes, Dockerfile, and custom regex managers.

```bash
# renovate: datasource=docker depName=busybox
```

The Phase 5 runbook's kube-prometheus-stack and blackbox-exporter chart version checks
carry `datasource=helm` annotations, so Renovate updates them on the same branch as
their `HelmRelease`, and the always-on CI checks job runs
`assert_phase5_observability_invariants` to fail any PR where they drift apart.

Renovate auto-merges only updates to the `renovate` npm package that pins the CI config
validator. That tool never reaches the cluster, and Renovate merges those PRs itself
(`platformAutomerge: false`) only after every check on the PR passes, since `main` has no
required status checks. Major validator updates still need Dependency Dashboard approval
before Renovate creates the PR. Every other update is attended. Renovate allows at most
five concurrent PRs and creates at most
five PRs per hour (overriding Renovate's default of two). It extends the built-in
`schedule:weekends` preset, so routine branch and PR work runs any time on Saturday or
Sunday in the configured America/Chicago timezone. Major versions require Dependency
Dashboard approval. Helm chart updates wait one day after release (`minimumReleaseAge`).
Flux refreshes each `HelmRepository` index only every 12 hours, so a chart bump merged
sooner can fail with `SourceNotReady` until the cache catches up, as #208 did on
2026-11-22. Until a release is a day old, Renovate offers the newest older release that
qualifies, or opens no PR. The Dependency Dashboard lists the pending update and can open
it early. Gluetun, SABnzbd, qBittorrent, Prowlarr, Radarr, and Sonarr are grouped into
one download-stack PR; unrelated applications remain separate. Updates for
`ghcr.io/sandersch/restic-backup` itself are disabled because the
`restic-backup-image` workflow owns that artifact, while `restic/restic` base updates
remain enabled and are released automatically on their PR branch (see
[custom Restic image](#custom-restic-image)).

Every image PR warns that merge changes production through Flux and links to the Phase
4/5 validators and rollback procedure. Before accepting normal PRs, confirm the
Dependency Dashboard finds each external dependency once logically, keeps the download
stack grouped, and gates majors.

### Weekend schedule interactions

The schedule controls only when Renovate creates new branches and PRs. Merging is
still attended, so it never starts a cluster change on its own. Renovate's default
`updateNotScheduled: true` keeps updating existing PRs on any day, including newer
releases of the same dependency. Re-read a PR's current version before merging rather
than relying on an earlier review. `main` does not require branches to be up to date,
so `rebaseWhen: "auto"` rebases a PR only when it conflicts with `main`. A clean PR
that falls behind `main` is not re-tested against it until merge, and then the full
suite runs on the `main` push. The Dependency Dashboard is refreshed on every run and
can create pending PRs before their scheduled time. Five concurrent PRs that each run
the full image-policy suite use more Actions minutes per weekend than the old six-hour
window did.

PRs can now arrive while weekend jobs on `minis` are running. When choosing when to
merge stateful or critical updates, avoid these windows (America/Chicago):

- Saturday 23:30 onward: the exclusive vault NAS/B2 prune
  ([backups runbook](../runbooks/backups/README.md)).
- Sunday 02:15–about 06:00: the vault backup, the 03:15 nightly appstate backup,
  the 04:30 appstate B2 copy, the 04:45 vault B2 copy, and the 05:30 workstation
  validations. Restarting Home Assistant or RomM during the appstate run can fail its
  required API backup or MariaDB dump.
- The first Sunday of each month, from 10:00: the md3 consistency check. It is known to
  stall Frigate I/O, which would confuse validation of a Frigate or storage-sensitive
  update.

Daytime Saturday and Sunday afternoon or evening leave a fresh nightly backup in place
before the merge, as the routine workflow below requires, and leave the 24-hour
observation running into the week.

## Custom Restic image

`containers/restic-backup/VERSION` is the canonical unique release/revision, such as
`0.19.0-1`. The Containerfile pins `restic/restic` by exact release and digest.
`runbooks/version-management/restic-release.py` performs the release bookkeeping:
`version --base <ref>` writes the next VERSION (`<upstream>-1` for a new Restic
release, the next revision for a digest-only base rebuild), `next-revision` skips a
taken tag, and `pin <image>@<digest>` rewrites every custom image reference that
`image_policy.py` finds.

### Renovate base updates (automatic)

When Renovate opens or updates a `restic/restic` PR, the `restic-backup-image`
workflow's `renovate-release` job checks out the PR head, bumps VERSION, publishes a
fresh GHCR tag (never overwriting one; an existing tag moves to the next revision),
pins its digest into every CronJob and recovery helper, and pushes that commit to the
PR branch as `github-actions[bot]`. Because pushes made with `GITHUB_TOKEN` do not
trigger `pull_request` workflows, it then dispatches `image-policy` for the new head
with the PR base SHA; the dispatched run always selects the full integration suite.
The PR is then ready for the normal attended merge below. Publishing from an open PR
is safe because Flux watches only `main`.

GitHub still creates `pull_request` runs for that pushed commit but holds them for
approval. They are redundant with the dispatched run and can be left unapproved.
Approving or re-running them is harmless: `restic-release.py version` compares the
Containerfile with the last release commit on the branch, so an already released
branch is a no-op and nothing is published.

`renovate.json5` lists `github-actions[bot]` in `gitIgnoredAuthors`, so Renovate keeps
managing the branch. When it rebases or picks up a newer Restic release it rewrites
its own commit, which reruns the job and publishes another tag; superseded tags remain
in GHCR unused. The job only runs for PRs authored by `renovate[bot]` from this
repository. If the push is rejected because Renovate pushed meanwhile, that push
starts a new run.

Host-installed Restic is separate: workstation clients, offline SSD, and legacy
rsnapshot tooling pin `0.19.1` in their own scripts and require an attended reinstall
via `workstation-install-restic.py`, so a cluster image update does not change them.

### Human changes (attended)

Pull requests from people build without publishing. To publish a reviewed change:

1. Bump the version/revision on the reviewed branch (or run `restic-release.py
   version --base origin/main`); never reuse a tag for changed build inputs.
2. Manually dispatch the workflow for that branch. It validates and builds first,
   refuses an already-existing GHCR tag, and then publishes.
3. Run the `restic-release.py pin ...` command from the run summary on the same branch
   and commit the result before merge.
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

Use [`runbooks/phase2/07-upgrade-k3s.sh`](../runbooks/phase2/07-upgrade-k3s.sh) for
the forward change and its validated checkpoint with `08-rollback-k3s.sh` if rollback
is required. The complete preflight, backup, acceptance, observation, and artifact
cleanup procedure is in the [Phase 2 runbook](../runbooks/phase2/README.md#attended-k3s-upgrade).
