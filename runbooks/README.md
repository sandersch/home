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

Later phases get their own subdirectories if manual work is scripted.

## Assumptions

- The repo is **checked out on the host** (the scripts resolve their config paths
  relative to their own location in the repo).
- You connect as the non-root sudo user (`charlie`) and have `sudo`.
- Scripts are idempotent and safe to re-run; interactive/destructive steps prompt
  first and assume "no" with no TTY.
