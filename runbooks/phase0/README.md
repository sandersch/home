# Phase 0 — OS baseline (runbook)

Scripts that execute [build-plan.md Phase 0](../../docs/build-plan.md#phase-0--os-baseline-)
**on the host**, starting from the point SSH is up and accepting connections (i.e.
0.0 BIOS and 0.1 OS install / first key copy are already done). They deploy the
canonical config from [`host/minis/etc/`](../../host/minis/) rather than inlining it.

## Prerequisites

- Ubuntu 24.04 installed; SSH reachable; you log in as `charlie` (non-root, sudo).
- Your SSH **public key is already authorized** for `charlie` (`ssh-copy-id`) — step
  01 refuses to lock you out if it isn't.
- This repo is checked out on the host.
- The expected NIC MACs are present. Preflight and step 02 fail before applying
  MAC-pinned netplan if either 2.5GbE port is missing.

## Order

Run in numeric order, or `./run-all.sh` to chain them. Keep a **second SSH session
open** across steps 01–02 (they restart sshd and reconfigure the network).

| Script | Build-plan step | What it does | Interactive? |
|---|---|---|---|
| `00-preflight.sh` | — | Read-only sanity checks (OS, NIC MACs, sudo, repo) | no |
| `01-hostname-ssh.sh` | 0.1 | hostname → `minis`; install key-only-auth drop-in; `sshd -t`; restart sshd | restart prompt |
| `02-networking.sh` | 0.2 | static netplan (lan0/cam0 by MAC); disable cloud-init net; `netplan apply` | apply prompt |
| `03-system-prep.sh` | 0.3 | apt upgrade; packages; tz `America/Chicago`; inotify limits; swap-off; hw checks; rfkill wifi/bt | swap-removal prompt |
| `04-bulk-storage-mounts.sh` | 0.4 | install md3 identity, attended check timers, and check-only speed cap; append four UUID mounts without overwriting the EFI-UUID fstab; verify exact LVM/ext4 mappings | no |
| `05-ups-nut.sh` | 0.5 | install NUT configs; restore redacted password (prompt); enable stack; `upsc` | password prompt |
| `06-coral-udev.sh` | 0.6 | install Coral udev rule; reload/trigger; check USB | no |

## Notes & gotchas

- **lan0/cam0 rename needs a reboot.** `netplan apply` can't rename a live, addressed
  link — the static addressing applies immediately to the current kernel names, but
  the friendly names appear only after a reboot.
- **Preflight is intentionally strict.** It fails on non-Ubuntu-24.04 hosts and on
  missing expected NIC MACs. To inspect behavior on another OS without editing the
  script, set `PHASE0_ALLOW_UNSUPPORTED_OS=1`, but the runbook is only supported on
  Ubuntu 24.04.
- **Storage layout is a preflight gate.** The installer-created layout must already
  match Phase 0.1: `/dev/vg0/root` on `/`, `/dev/vg0/var` on `/var`, `/dev/vg0/opt`
  as btrfs on `/opt`, and at least 500 GiB free in `vg0` for TopoLVM scratch.
- **Swap must be fully off.** Step 03 stops if any swap remains active or if active
  swap entries remain in `/etc/fstab`; k3s will not run correctly otherwise.
- **Inotify capacity is raised.** Step 03 installs the canonical sysctl drop-in and
  verifies 524288 watches and 8192 instances per user after applying it.
- **Quick Sync is a Phase 0 gate.** Step 03 fails if `/dev/dri`, `i915`, or the
  `render` group is missing. If it adds `i915` to `/etc/modules`, reboot and re-run.
- **Bulk storage identity is strict.** Step 04 triggers all four automounts and checks
  both the expected `hoardvg` device and filesystem UUID; root-directory fallthrough
  or an unexpected filesystem fails the runbook.
- **fstab is not overwritten.** The repo's `fstab` carries a disk-specific `/boot/efi`
  UUID; step 04 only appends the four canonical bulk-storage lines if missing.
- **NUT password.** The repo ships `__REPLACE_WITH_UPSMON_PASSWORD__`; step 05 prompts
  and substitutes it into a temp file on first install — never committed, and the
  placeholder is never written onto a live file. On rerun, it extracts the existing
  matching live password and re-renders the current repo templates with that password,
  so non-secret NUT config changes still apply without rotating the secret.
- **0.7 Router DNS is off-host and not scripted.** Add the wildcard
  `*.worm.run → 10.137.20.10` on the router manually.
- After Phase 0, **reboot once** to settle the interface rename, then proceed to
  Phase 1 (camera-segment isolation).

## Keeping in sync

The scripts copy from `host/minis/etc/` — that directory stays the source of truth.
If host config changes, update the file there (see
[host/minis/README.md](../../host/minis/README.md#keeping-these-in-sync)); the scripts
need no edits.
