# Runbooks

Executable, idempotent scripts that carry out the **manual host phases** of the
[build plan](../docs/build-plan.md), one subdirectory per phase. They run **on the
host** (`minis`) and deploy the canonical config from
[`host/minis/etc/`](../host/minis/) into place — they do not duplicate that config,
they copy it, so `host/minis/etc/` stays the single source of truth.
Shared shell helpers live in [`lib.sh`](./lib.sh); each phase keeps only its
phase-specific assertions in its own `lib.sh`.

These complement the prose in `docs/build-plan.md`; they don't replace it. Read the
phase section there first, then run the scripts.

| Phase | Dir | Covers |
|---|---|---|
| 0 | [`phase0/`](./phase0/) | OS baseline from SSH-ready: hostname, SSH hardening, networking, system prep, NFS, UPS/NUT, Coral udev |
| 1 | [`phase1/`](./phase1/) | Camera-segment isolation: nftables, DHCP-only dnsmasq, chrony NTP, Catalyst checklist, validation, NAS throughput |
| 2 | [`phase2/`](./phase2/) | k3s install, SOPS age key/secret, `.sops.yaml`, and Flux bootstrap |
| 3 | [`phase3/`](./phase3/) | SOPS-encrypted infra secrets, Flux reconciliation, and platform validation gate |
| 3.5 | [`phase3.5/`](./phase3.5/) | Final stopped-host app-data copy from the NAS archive into `/opt` |
| 4 | [`phase4/`](./phase4/) | Secret helpers, host config install, and validation for download stack, Plex, Seerr, RomM, and Frigate |
| 5 | [`phase5/`](./phase5/) | NAS/B2 Restic setup and validation plus encrypted external-heartbeat and Pushover notification workflows |

## Assumptions

- The repo is **checked out on the host** (the scripts resolve their config paths
  relative to their own location in the repo).
- You connect as the non-root sudo user (`charlie`) and have `sudo`.
- Scripts are idempotent and safe to re-run; interactive/destructive steps prompt
  first and assume "no" with no TTY.
