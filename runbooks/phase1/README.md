# Phase 1 - networking isolation (runbook)

Scripts and checklists for [build-plan.md Phase 1](../../docs/build-plan.md#phase-1--networking-isolation-).
They run on `minis` and install canonical host config from
[`host/minis/etc/`](../../host/minis/etc/). Switch-side camera isolation is documented
separately because it belongs on the Catalyst, not on the Ubuntu host.

## Prerequisites

- Phase 0 is complete and the host has rebooted once after netplan, so `lan0` and
  `cam0` are active names.
- `lan0` has `10.137.20.5/24`; `cam0` has `192.168.105.1/24` and `192.168.1.2/24`.
- Phase 0.3 packages are installed: `nftables`, `dnsmasq`, and `chrony`.
- A test laptop/device is available for validation on the camera segment.
- Catalyst camera-port isolation is configured or ready to validate before any real
  camera is connected.

## Order

Run the host-side scripts in numeric order, or run `./run-all.sh` for steps 00-02.

| Script | Build-plan step | What it does | Interactive? |
|---|---|---|---|
| `00-preflight.sh` | - | Read-only Phase 0 and package sanity checks | no |
| `01-host-isolation.sh` | 1.1 | Installs nftables camera isolation and disables IPv6 on `cam0` | no |
| `02-camera-dhcp-ntp.sh` | 1.2, 1.3 | Installs DHCP-only dnsmasq config and chrony camera NTP config | no |
| `catalyst-camera-isolation.md` | 1.1b | Manual Catalyst protected-port checklist and traffic validation | yes, off-host |
| `03-camera-segment-validation.sh` | 1.1-1.3 | Validates DHCP/NTP/input-chain isolation with a test device | yes |
| `04-direct-storage-throughput.sh` | 1.4 | Verifies the media UUID/device mapping and runs a 256 MiB local read/write probe | prompts |

## Notes

- `01-host-isolation.sh` replaces `/etc/nftables.conf` with the canonical file, but
  that file manages only the `camera_isolation` table. It does not use `flush ruleset`,
  so later k3s nft/iptables state is not wiped on reload.
- **After Phase 2, reload nftables, never restart it.** Stock Ubuntu's `nftables.service`
  ships `ExecStop=/usr/sbin/nft flush ruleset`, so `systemctl restart nftables` (stop+start)
  flushes *every* table — including the nat/filter/mangle chains k3s/flannel/kube-proxy
  inject at runtime — and pod networking breaks until k3s re-syncs. `01` and any later
  rule change must use `systemctl reload nftables`, which only re-applies our conf file.
- The camera DHCP/NTP config ships as drop-ins only, so `02-camera-dhcp-ntp.sh` ensures
  `/etc/dnsmasq.conf` and `/etc/chrony/chrony.conf` include their `conf.d` dirs. If an
  OS upgrade drops those includes, the daemons start cleanly but silently ignore the
  camera config; the runbook restores the include before restarting them.
- Before k3s, stock Ubuntu usually has `net.ipv4.ip_forward=0`, so camera-to-LAN or
  camera-to-internet ping failures do not prove the forward chain. Re-test after Phase 2
  with a camera-segment test device using manual gateway `192.168.105.1`; blocked
  packets should produce `cam-drop-fwd-*` kernel logs.
- Real cameras should not be connected until Catalyst protected-port isolation passes.
- The committed dnsmasq config pins the deployed Amcrest camera at `.50`. Add one
  reservation in the `.50-.99` static block for every additional camera before adding
  it to Frigate; the dynamic pool remains `.100-.199` for discovery/provisioning.
- Camera UI access from the LAN should be via SSH port forward through `minis`, not by
  opening routed access to VLAN 105.

## Keeping in sync

The scripts copy from `host/minis/etc/`. If the live host config changes, update the
matching source file in `host/minis/etc/` so future rebuilds use the same state.
