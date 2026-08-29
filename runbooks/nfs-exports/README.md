# NFSv4 exports from `minis` (runbook)

Exports `/mnt/media` and `/mnt/games` from `minis` over NFSv4 to VLAN 20 servers and
VLAN 30 trusted clients. Scripts run on `minis` and install canonical host config from
[`host/minis/etc/`](../../host/minis/etc/). See
[operations.md → NFS exports](../../docs/operations.md#nfs-exports) for the deployed
design and day-to-day procedures.

Scope is exactly those two filesystems. `/mnt/frigate` stays local to the colocated
Frigate workload and `/mnt/backups` stays unexported.

## Prerequisites

- Phases 0–2 are complete: `lan0` is `10.137.20.5/24`, all four bulk mounts are healthy,
  and k3s is running.
- `nfs-kernel-server` is installed (Phase 0.3 installs it disabled, and masks
  `rpcbind`, `rpc-statd`, `rpc-statd-notify`, and `rpc-gssd` at the same time so
  rpcbind never holds `0.0.0.0:111` open in the gap before this workflow runs).
- `nftables` is active with the `camera_isolation`, `frigate_access`, and `ups_access`
  tables loaded.
- A second machine on VLAN 20 or 30 for the client gates, and a host on VLAN 60 or 80
  (or a Tailnet client) for the negative gates.

## When to run it

Run `00`–`03` after Phase 2 and **before Phase 3 reconciles `monitoring-configs`**, then
`04-validate-monitoring.sh` once Prometheus is up — which is why the monitoring gate is a
separate script.

`monitoring-configs` carries this workflow's blackbox probe, and the probe cannot tell
"not deployed yet" from "down": if it reconciles while nothing is listening on 2049,
`StandardEndpointDown` pages after ten minutes. The two `homelab.nfs` rules that read
nfsd's own metrics are gated so they stay silent on a host that has never run this
workflow (see `infrastructure/monitoring/configs/alert-rules.yaml`), so the probe is the
only piece that depends on this ordering.

That gating covers the skip case only for the rules, not the probe. **The monitoring
slice is not optional in the way the exports are:** if you decide not to serve NFS from
`minis`, drop the `nfs` Probe from `blackbox-probes.yaml` and the `homelab.nfs` group from
`alert-rules.yaml` in the same change, exactly as you would for any other service the
cluster does not run. Leaving them in place means a permanently firing warning.

## Order

| Script | What it does | Interactive? |
|---|---|---|
| `00-preflight.sh` | Read-only mount, package, ownership, and firewall sanity checks | only if `/etc/exports` already differs |
| `01-install-server-config.sh` | Installs the NFSv4-only drop-in, `/etc/exports`, and the unit ordering drop-in; masks the v3 units; starts nfsd | no |
| `02-firewall.sh` | Installs the `nfs_access` nftables table and reloads (never restarts) nftables | no |
| `03-validate.sh` | Server-side gates plus attended client mount, squash, v3-refusal, and cross-VLAN negative tests | yes |
| `04-validate-monitoring.sh` | Prometheus probe, `homelab.nfs` rules, and nfsd-collector gates; optional alert drill | prompts only for the drill |

## Design notes

- **Listener scope is not an ingress policy.** `nfs.conf.d/10-homelab.conf` opens nfsd
  sockets only on `10.137.20.5` and `127.0.0.1`, not on `cam0`'s addresses or a wildcard
  address. A packet can nevertheless arrive through another interface with
  `10.137.20.5` as its destination. The `nfs_access` nftables table therefore enforces
  the source/interface packet policy, while `/etc/exports` independently authorizes
  VLAN 20/30 client addresses for mounts.
- **No UDM firewall change is needed.** Rule 110 already allows VLAN 30 → VLAN 20 on all
  ports, VLAN 20 → VLAN 20 is intra-subnet and unrouted, and Rules 900/910 already drop
  Guest/IoT → internal. The export therefore *depends* on Rule 110 — note that before
  ever narrowing it.
- **Reload nftables, never restart it.** Stock Ubuntu's `nftables.service` ships
  `ExecStop=/usr/sbin/nft flush ruleset`, so a restart flushes the nat/filter/mangle
  chains k3s/flannel/kube-proxy own. `02-firewall.sh` only reloads.
- **The pod-CIDR allow in `nfs_access` is for monitoring only.** It exists so the
  in-cluster blackbox exporter can probe 2049. No pod mounts NFS; the media apps use
  `hostPath`, and `/etc/exports` does not authorize the pod CIDR.
- **`rpc.mountd` is deliberately not masked.** Even under v4-only, nfsd uses it as the
  export-authentication upcall handler. `rpcbind`, `rpc-statd`, `rpc-statd-notify`, and
  `rpc-gssd` are masked — by Phase 0.3 on a clean build, and re-verified by
  `01-install-server-config.sh`, which shares the `NFS_MASKED_UNITS` list with it via
  `runbooks/lib.sh`. If a future release makes `nfs-server` genuinely require
  `rpcbind`, unmask `rpcbind.socket`, record why in `docs/operations.md`, and re-run.
- **The `mountpoint` export option is a weaker guard than it looks.** `fstab` uses
  `x-systemd.automount`, so an autofs mount is present on both paths even before the
  real ext4 filesystem mounts. The real coverage for an unmounted volume is the existing
  `BulkStorageMountSetIncomplete` alert, plus the fact that nfsd access triggers the
  automount.

## Squash policy

| Export | Policy | Why |
|---|---|---|
| `/mnt/media` | `root_squash` | Every local consumer runs as uid 1000 (Plex/*arr `PUID=1000`; mount root `1000:100` `0775`), so a workstation user at uid 1000 writes files the pods can rewrite. Remote root maps to the anonymous `65534:65534`, which is "other" against a `1000:100` `0775` root and so cannot write there at all. Under `sec=sys` this trusts each client's uid mapping: a client user neither uid 1000 nor in gid 100 also cannot write at the root, and one in gid 100 writes files the apps cannot rewrite. Every workstation mounting this read/write must use uid 1000 — the accepted cost of keeping per-user identity on the shared library. |
| `/mnt/games` | `all_squash,anonuid=1000,anongid=1000` | Batocera runs its whole userland as root and RetroPie images vary, so client uid coordination is not achievable. Squashing to `1000:1000` matches RomM's `runAsUser: 1000` and the `1000:1000` `0755` mount root exactly, making ownership drift structurally impossible. |

## Client mount options

See [operations.md → NFS exports](../../docs/operations.md#nfs-exports) for the full
option-by-option rationale, including why `hard` (never `soft`), why `nfsvers=4.2` is
pinned, and why `nconnect` and explicit `rsize`/`wsize` are deliberately omitted.
