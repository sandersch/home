# Runbooks

Executable, idempotent scripts that carry out the **manual host phases** of the
[build plan](../docs/build-plan.md), one subdirectory per phase. Phase scripts run
**on the host** (`minis`) and deploy the canonical config from
[`host/minis/etc/`](../host/minis/) into place — they do not duplicate that config,
they copy it, so `host/minis/etc/` stays the single source of truth.
Shared shell helpers live in [`lib.sh`](./lib.sh); each phase keeps only its
phase-specific assertions in its own `lib.sh`.

Three directory-level workflows are exceptions to the normal `minis` phase
execution model. Run the attended
[`direct-attached-storage-migration/`](./direct-attached-storage-migration/)
helpers on whichever host currently owns the enclosure. The guarded
[`disaster-recovery/`](./disaster-recovery/) workflow runs in the recovery
environment and composes the phase validators with a real staged Restic `/opt`
restore and ordered Git-based resume. The attended
[`bastion/`](./bastion/) workflow runs on the separate OpenBSD Wyse from its
physical console; its transfer, bootstrap, and privilege rules are summarized
below and specified fully in its own README.

These complement the prose in `docs/build-plan.md`; they don't replace it. Read the
phase section there first, then run the scripts.

| Phase | Dir | Covers |
|---|---|---|
| 0 | [`phase0/`](./phase0/) | OS baseline from SSH-ready: hostname, SSH hardening, networking, system prep, direct bulk storage, UPS/NUT, Coral udev |
| 1 | [`phase1/`](./phase1/) | Camera-segment isolation: nftables, DHCP-only dnsmasq, chrony NTP, Catalyst checklist, validation, direct-storage probe |
| 2 | [`phase2/`](./phase2/) | k3s bootstrap and attended upgrade/rollback, SOPS age key/secret, `.sops.yaml`, and Flux bootstrap |
| 3 | [`phase3/`](./phase3/) | SOPS-encrypted infra secrets, Flux reconciliation, and platform validation gate |
| 3.5 | [`phase3.5/`](./phase3.5/) | Final stopped-host app-data copy from the bulk-storage archive into `/opt` |
| 4 | [`phase4/`](./phase4/) | Secret helpers and validation for media apps, Frigate, Home Assistant, MQTT, Z-Wave JS, and Zigbee2MQTT |
| 5 | [`phase5/`](./phase5/) | Direct-array/B2 Restic setup and validation plus encrypted external-heartbeat and Pushover notification workflows |
| DR | [`disaster-recovery/`](./disaster-recovery/) | Fresh full-state `/opt` restore, hot-database recovery, and two-stage app/monitoring resume validation |
| Bastion | [`bastion/`](./bastion/) | Attended OpenBSD 7.9 Wyse preflight, interface-aware config staging, trunk activation, validation, and rollback |

## Assumptions

The following assumptions apply to the `minis` phase, migration, and disaster
recovery runbooks unless their own README narrows them:

- The repo is **checked out on the host** (the scripts resolve their config paths
  relative to their own location in the repo).
- You connect as the non-root sudo user (`charlie`) and have `sudo`.
- Phase scripts are idempotent and safe to re-run. Disaster recovery uses a recorded
  state machine so only the same interrupted recovery can resume. Interactive or
  destructive steps prompt first and assume "no" with no TTY.

The bastion workflow has a separate OpenBSD contract: transfer only
`runbooks/bastion/` and `host/bastion/` in their repository-relative layout. A
fresh install has no active `doas` policy, so run preflight and staging from a
root login shell at the local console; staging installs the canonical
`/etc/doas.conf`, and later privileged steps run through `doas` as `charlie`.
Its scripts use POSIX `/bin/sh` and their own `runbooks/bastion/lib.sh`; they
deliberately do not source the Linux-oriented shared `runbooks/lib.sh`. Follow
the attended local-console and re-run constraints in
[`bastion/README.md`](./bastion/README.md).
