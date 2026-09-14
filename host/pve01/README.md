# Add pve01 as an independent infrastructure and recovery host

> **Status: proposed, not deployed.** This plan records the design discussed on
> 2026-09-12. Addresses and allocations below remain subject to the stated
> preflight and acceptance gates.

## 1. Architecture and resource allocation

Install standalone Proxmox on the Optiplex, with four small VMs. Keep minis as the production application host and retain its existing backups and hardware-dependent services.

This adds a separate copy of enrolled backups and monitoring outside minis's Kubernetes stack. Availability after a minis host failure is limited by the shared power-management dependency: loss of its NUT service initiates pve01 shutdown after five minutes. Replica access may then require attended recovery. The shared UPS, UDM, and physical location remain common failure points; B2 and the two external heartbeats retain their roles.

Use these initial allocations and proposed addresses, subject to address-conflict checks:

| System | Role | vCPU / RAM | SSD disks | VLAN addresses |
|---|---|---:|---:|---|
| `pve01` | Hypervisor, host NUT secondary, hardware monitoring | Reserve 4 GiB for host | 64 GiB root, 8 GiB swap | `10.137.10.12` |
| `net01`, VM 101 | OpenBSD NTP appliance | 1 / 1 GiB | 16 GiB boot | `.20.13`, `.30.13`, `.60.13` |
| `backup01`, VM 102 | Opaque repository replicas | 2 / 2 GiB | 32 GiB boot | `10.137.20.14` |
| `mon01`, VM 103 | Independent monitoring | 2 / 4 GiB | 32 GiB boot + 64 GiB history | `.20.15`, `.30.15`, `.60.15` |
| `nas01`, VM 104 | Disposable NFS workspace | 1 / 2 GiB | 16 GiB boot | `10.137.20.12` |

Addresses abbreviated in the table retain the `10.137` prefix. Guest RAM totals 9 GiB, leaving approximately 3 GiB beyond the host reservation. Disable ballooning initially.

Use Proxmox VE 9.2 with current stable maintenance packages, OpenBSD 7.9 following the bastion baseline, and Debian 13 minimal installations for the Linux guests. Record installed versions and verified installation-media checksums. Use attended updates and the no-subscription Proxmox repository by default. [Proxmox release information](https://www.proxmox.com/en/about/company-details/press-releases/proxmox-virtual-environment-9-2)

Do not move camera DHCP/NTP, existing NFS exports, or the UPS USB connection from minis. Defer DNS expansion, ConnectX-4 networking, and k3s membership. Joining a second k3s node later would require a separate storage and availability design.

## 2. Network and service boundaries

**Physical and virtual networking**

- Use an available UDM gigabit port, with native VLAN 99 and tagged VLANs **10, 20, 30, 60 only**. Record the exact port and physical NIC identity during preflight.
- Configure one VLAN-aware Linux bridge, with its parent and untagged interface unnumbered. Place the host address on VLAN 10.
- Give each VM one hypervisor-tagged access vNIC per required VLAN. Guests receive no trunk. Use fixed MACs, static addresses, MTU 1500, and one default gateway per guest.
- Disable routing, NAT, and IPv6 autoconfiguration in these guests. Apply Proxmox per-vNIC source filtering and service rules as well as guest firewalls; traffic between guests can bypass the UDM.
- Use the established Proxmox firewall implementation, explicitly narrowing its management allowances. Verify the effective rules rather than relying on default-deny settings alone.

Hypervisor SSH and HTTPS administration is allowed only from bastion's `10.137.10.9`. Use key-only SSH and a named Proxmox administrator with MFA; retain console recovery credentials externally.

Add narrowly scoped UDM exceptions for:

- `pve01` → minis TCP 3493 for NUT.
- minis → a dedicated, export-only SSH listener on pve01 for backup retrieval.
- minis and `mon01` → pve01's metrics listener.
- pve01's necessary update egress; DNS uses `10.137.10.1`, and NTP uses bastion.

The backup listener must provide no interactive or forwarding access. Monitoring receives no administrative Proxmox API credential. Preserve Rule 940 and document these service exceptions separately from administrative access. The remaining undeployed firewall matrix must continue to be identified as intended state.

**OpenBSD appliance**

Adapt the bastion configuration, using ordinary guest interfaces instead of guest VLAN interfaces:

- Serve UDP 123 separately on VLANs 20, 30, and 60, accepting only the corresponding directly attached subnet.
- Bind key-only SSH to VLAN 30; disable all SSH forwarding, agent forwarding, tunnels, and root login.
- Use VLAN 30 for the sole default route, UDM DNS, pinned external NTP peers, HTTPS time constraint, and privilege-restricted update retrieval.
- Keep the base-only installation and PF default-deny pattern.
- Leave bastion and minis upstream time configurations independent. pve01 also uses bastion, avoiding a host-to-guest time dependency.

Publish explicit per-VLAN NTP service records and advertise each local address through DHCP option 42 after validation. Configure clients that ignore that option explicitly. Do not change general internet-NTP access policy as part of this addition.

**Independent monitoring**

Run Prometheus, Alertmanager, blackbox exporter, node exporter, and Grafana as native systemd services with configuration in git. Keep browser interfaces on loopback, accessed through SSH tunnels to `mon01` on VLAN 30.

- Use local scraping and direct probes, with no dependency on minis Prometheus, ingress, or an Alertmanager cluster.
- Probe minis host availability, existing application HTTPS endpoints, backup freshness, and the new host/VMs. Probe bastion's SSH banner through VLAN 30.
- Check the NTP appliance from all three attached VLANs using an actual NTP client probe that checks replies, synchronization, and offset. Blackbox exporter does not provide an NTP prober. Observe bastion NTP through pve01's client health.
- Restrict probe destinations and ports on each vNIC. Do not give the monitoring guest VLAN 10 access.
- Give this Alertmanager its own Dead Man's Snitch URL and Pushover application token. Emit the heartbeat every five minutes through the Prometheus → Alertmanager path.
- Have minis independently monitor `mon01` and pve01. Label notifications with the observing system; accept duplicate reports for a host outage.
- Start with 30-day Prometheus retention and a 48 GiB size limit on the separate history disk. Alert on exporter absence as well as unhealthy reported values.

Use UDM DNS and independent external clock synchronization on `mon01`, so notification delivery has no DNS or clock dependency on minis or `net01`. A minis host or NUT-service failure still initiates pve01 shutdown after five minutes; monitoring then stops and its external heartbeat expires. Independence from the minis monitoring stack does not imply continued availability after loss of minis's NUT service.

## 3. Storage and backup design

**Local allocation**

Use separate SSD and HDD volume groups and **thick, Proxmox-managed VM disks**. No physical disk passthrough or shared thin pool.

On the SSD, allocate the table's disks, a separate **160 GiB backup staging LV**, and **16 GiB installation-media LV**. Leave the remaining approximately 55 GiB unallocated after boot partitions.

On the 6 TB HDD, allocate:

- **3 TiB** to backup01's replica disk.
- **1 TiB** to nas01's disposable disk.
- Approximately **1.45 TiB** unallocated.

Use ext4 for Linux filesystems. The 1 TiB scratch allocation is approximately 1.1 decimal TB.

Separate LVs prevent scratch capacity exhaustion from consuming replica or boot space. They do not isolate HDD latency. Initially cap replica transfers and scratch disk throughput at 40 MiB/s each, then validate simultaneous workload impact.

NAS exports only the disposable filesystem through NFSv4.1/4.2 over TCP 2049. Reuse minis's protocol restrictions, listener scoping, mount guards, and auxiliary-service masking. Authorize ryze and m5c explicitly, with `all_squash` to a dedicated `1000:1000` scratch account. Publish `scratch.nfs.service.matrix` as an explicit override of the existing minis wildcard.

**Opaque replicas of minis repositories**

Initially enroll appstate, vault, and workstation repositories that have passed their enrollment gates. Existing directory presence alone is insufficient. Exclude legacy backup trees and the new pve01 backup repository.

Live measurements found approximately **66 GiB** across these candidate repositories and **9.8 TiB free** in minis's bulk VG.

Implement the replica pipeline as follows:

1. A root-owned minis timer prepares a source export nightly at **07:00 America/Chicago**. The replica VM cannot invoke snapshot operations.
2. Introduce a common maintenance gate around destructive operations on enrolled repositories, including inline appstate prune and workstation rejection cleanup. Snapshot creation briefly takes exclusive ownership of that gate. Interrupted maintenance leaves a hold requiring successful source validation before publication.
3. Ordinary append-only uploads may continue, relying on atomic repository-object publication. Validate this explicitly against the deployed Restic and rest-server versions.
4. Create a bounded LVM snapshot of `backuplv`, initially with **128 GiB COW space**. Expose only enrolled ciphertext repository trees and a sanitized generation receipt through a read-only export. Do not expose the whole backup filesystem.
5. Give backup01 a dedicated SSH identity restricted to read-only rsync access to that export, with pinned host keys and no shell or forwarding.
6. Build each destination generation in a private staging directory using `rsync --link-dest`. Verify inventory and content hashes. Never update retained files in place, including their shared inode metadata. Before publication, successfully flush new file contents, the generation manifest, and all changed directory entries to disk. Atomically rename the generation within the same filesystem and flush the affected parent directories. A successful rename or hash check alone is not durable publication; any write or flush failure aborts success. Validate that the VM disk cache and storage stack honor flushes. [Linux file and directory synchronization](https://man7.org/linux/man-pages/man2/fsync.2.html)
7. Only after durable publication, atomically write and durably flush a receiver receipt identifying the source generation, repository inventory/manifest digest, destination generation, and receiver completion time. Expose receipts through authenticated read-only retrieval by minis. Advance freshness and permit retention rotation only after this receipt is durable. Retain the union of **14 daily and 8 weekly successful generations**, selected using receiver timestamps; capacity pressure must not silently shorten retention.

Serialize receiver publication and retention. After restart, reconcile generations and receipts before accepting new work: incomplete staging never counts as success, and a published generation without a durable receipt must be revalidated and flushed before issuing one. Retries for the same source generation reuse its identity and completion record rather than creating another daily success. Preserve the previous successful generations until the new commit is complete; interrupted retention must be safely resumable without deleting any generation still selected by policy.

Minis owns snapshot cleanup. Release it after observing a matching durable successful receiver receipt, with an eight-hour hard expiry. Warn at 70% COW usage and withdraw the export at 85%; failed or expired transfers never advance success. Expiry may release source resources without a receipt, but is recorded as failure, not successful delivery.

Alert after **36 hours without a successfully published fresh generation**, and separately on source backup staleness. Recopying an unchanged, stale repository must not imply a fresh source backup.

Ciphertext hashes verify transfer integrity, not application recoverability. Perform authenticated checks and restore drills from a trusted recovery machine using externally supplied passwords. Never install existing Restic passwords or B2 credentials on backup01. Restore through a writable copy, preserving retained generations. Restic's immutable, content-addressed repository objects support this file-sharing approach. [Restic repository format](https://restic.readthedocs.io/en/stable/100_references.html)

**Backups of pve01 itself**

Use Proxmox's standard `vzdump` archives, with minis managing a dedicated encrypted Restic repository and B2 copy:

- Capture host configuration daily, VM boot disks weekly, and both before upgrades.
- Include consistent pmxcfs configuration/database exports, host networking/firewall/NUT configuration, VM definitions, and required recovery secrets.
- Use live backups with QEMU guest-agent filesystem freezing for Linux guests. Use `stop` mode for OpenBSD, accepting its brief restart.
- Mark replica, scratch, and monitoring-history disks `backup=0`. These exclusions must also be reflected in recovery procedures.
- Stage uncompressed, validated VMA archives on pve01's bounded SSD staging filesystem. Retrieve them through the dedicated read-only export and ingest using Restic's command-aware streaming mode; transfer or checksum failure must fail the backup.
- Allocate a separate **512 GiB LV on minis** for this repository, avoiding competition with the existing 1 TiB backup filesystem.
- Copy each successful backup to a dedicated B2 destination. Keep 14 daily/8 weekly host-config snapshots and 8 weekly/12 monthly VM snapshots, with per-artifact grouping.
- Keep Restic/B2 credentials on minis and in external recovery storage. Exclude this repository from backup01 replication to prevent recursive backup growth.

**Archive staging, acknowledgment, and retries**

The 160 GiB staging LV is a transfer queue, not an additional retention tier. The four boot disks total 96 GiB, so it must not depend on fitting two complete uncompressed backup sets. Apply the same lifecycle to host-configuration bundles:

1. Use one pve01 capture/cleanup lock across scheduled and pre-upgrade jobs. Capture and hand off one artifact at a time; do not begin another capture while a completed artifact awaits local-ingestion acknowledgment. Check the staging mount identity and free space before capture, budgeting the included disks' full logical size plus archive overhead and a safety reserve. Fail and alert without overwriting pending artifacts if the budget does not fit.
2. Capture under a private temporary name. After successful archive validation, compute its checksum and record a unique artifact ID, VM/host identity, capture time, included/excluded disks, size, and checksum in a manifest. Flush the artifact and manifest, then publish them durably in the read-only export. Never expose a growing archive as ready. On interruption, pve01 may remove its own confirmed inactive partial capture; preserve completed unacknowledged artifacts.
3. Minis retries ingestion of the same immutable artifact. Coordinate ingestion, copy tracking, and retention so every newly ingested snapshot is protected from pruning until its lifecycle state is reconciled. Require successful command-aware streaming and a read-back from the resulting Restic snapshot whose byte count and checksum match the manifest. Durably record the pending B2 copy and its retention pin before publishing a durable acknowledgment binding the artifact ID and checksum to the repository and Restic snapshot ID. Reconcile an existing matching snapshot after an interrupted acknowledgment instead of treating the retry as a new capture or advancing its capture timestamp.
4. Pve01 alone removes staged artifacts, after retrieving and validating the matching acknowledgment through an authenticated read-only receipt endpoint on minis. Record this service flow and its host/UDM allowances during implementation; the export identity must not acquire deletion, shell, or forwarding privileges. Cleanup and acknowledgment processing are idempotent. A missing, mismatched, or unreadable acknowledgment preserves the archive and blocks subsequent capture, including a pre-upgrade capture; the affected upgrade must wait for its required backup.
5. A verified local-ingestion acknowledgment releases pve01 staging even while B2 is unavailable. Minis durably tracks pending B2 copies and pins their local Restic snapshots against retention until the corresponding B2 snapshot is verified by artifact identity and restored checksum. Retry from minis without recapturing the VM. If the dedicated repository cannot accommodate pending copies plus a new ingestion, fail and alert before acknowledgment; never discard an unreplicated snapshot to make room.

Alert on capture/validation/ingestion failures, staging capacity rejection, acknowledgments pending for more than 24 hours, and B2 copies pending for more than 24 hours. Also alert independently on missing or stale verified artifacts per host/VM and destination: 36 hours for daily host configuration and 8 days for weekly VM backups. Track capture time separately from ingestion and copy completion so retries cannot make an old backup appear fresh. Enrollment initializes the expected artifact set so a backup that has never succeeded is not invisible.

Proxmox VM backups do not require snapshot-capable underlying storage. [Proxmox backup behavior](https://raw.githubusercontent.com/proxmox/pve-docs/master/vzdump.adoc)

## 4. Power management and operating model

Keep the existing shared UPS; no additional UPS is planned. Keep minis as NUT primary with its existing direct USB shutdown path and short shutdown delay. Install the NUT secondary on **pve01 itself**, using a separate secondary-only credential and exact source allowances in minis's host firewall.

Configure pve01 to initiate orderly shutdown on:

- NUT forced-shutdown or critical-battery status.
- Two minutes of continuous on-battery status, providing time to stop VMs.
- Five minutes without valid NUT communication, including unknown status after boot.

Provide a deliberate, expiring maintenance override for the communication-loss timer only when pve01 has been moved to independently protected power. On the shared UPS, keep that timer active even during minis maintenance: it limits operation without power telemetry, but cannot guarantee shutdown before UPS output loss. Export and alert on override activation and expiry. Never suppress shutdown after a confirmed critical UPS condition.

**Accepted reduced availability (2026-09-13):** a minis host or NUT-service failure can shut down pve01 despite healthy mains power. Retained replicas remain on its HDD, but monitoring, NTP, NAS, and replica access are unavailable while pve01 is off. Recovery requires restoring minis's NUT service or arranging independently protected power with the attended override. If neither is available, use the existing B2 recovery path until replica access can be restored. Do not bypass the timer merely to keep pve01 running on the shared UPS.

Start monitoring first, then networking, replicas, and NAS; reverse that order during shutdown. Validate ACPI shutdown for OpenBSD and guest-agent shutdown for Linux. Bound total guest shutdown time to three minutes, including timeout escalation and any backup locks. Use one idempotent host shutdown path for all three triggers; repeated events must not restart its deadline. The early on-battery and communication-loss timers shut down pve01 locally and cannot request UPS output cutoff or set FSD on minis.

**Accepted manual recovery:** if pve01 shuts down after communication loss while UPS output remains powered, the operator may need to power it on manually or cycle power to pve01 after shutdown completes. Automatic restart is not required for this case; its hosted services remain unavailable until that intervention. Before restarting, confirm healthy mains/UPS status and restore NUT communication, or use the independently protected power and maintenance override described above. This restart policy resolves review finding 3 (P2), as accepted on 2026-09-13.

**Minis protection and limits of shared-UPS shutdown**

Retain minis's [`HOSTSYNC 15`, `FINALDELAY 5`](../minis/etc/nut/upsmon.conf). Remove the proposed long primary delay, shared shutdown budget, and associated 900-second runtime watchdog from this design. Native low-battery/FSD handling must initiate minis shutdown promptly without waiting for pve01's guests to finish. `HOSTSYNC` only bounds the wait for NUT clients to disconnect; a disconnect does not prove guest shutdown or host power-off. [NUT timing settings](https://networkupstools.org/docs/man/upsmon.conf.html)

The two-minute on-battery timer is pve01's normal early shutdown path. Use a monotonic five-minute deadline from the last valid NUT status for communication loss, including a bounded initial wait after boot. Native critical-battery/FSD handling takes precedence over either timer and any communication-loss override. Keep pve01's secondary `FINALDELAY` short (initially five seconds). All triggers use the same bounded shutdown path; neither a stuck guest nor an active backup may extend minis's shutdown delay.

This arrangement cannot guarantee graceful pve01 shutdown before shared UPS output loss. An urgent low-battery event, missed early notification, or communication failure just before FSD can leave guests running when minis commands cutoff. The timers reduce that exposure but do not reserve power for pve01. Abrupt interruption can require guest/filesystem recovery and checking retained replicas; do not describe it as a successful graceful shutdown or promise replica integrity after every power event.

Audit minis's installed NUT/systemd units, effective `POWERDOWNFLAG` handling, and late driver shutdown command. Only minis's late shutdown hook may command UPS output cutoff, after minis has quiesced its own filesystems. Verify the actual CP1500 driver, firmware, and effective `offdelay`; do not credit an unmeasured output delay as guest shutdown time. [USB HID shutdown behavior](https://networkupstools.org/docs/man/usbhid-ups.html)

The current [`override.battery.runtime.low = 300`](../minis/etc/nut/ups.conf) is not proof of a hardware-programmed early low-battery threshold. Validate minis's actual native low-battery behavior and shutdown margin at combined load; preserve its hardware low-battery signal. Production enrollment requires adequate measured margin for minis's own shutdown and a successful normal early-shutdown drill for pve01. Shorten pve01's on-battery timer or guest shutdown limits if necessary; do not extend minis's delay to make the drill pass. [NUT threshold semantics](https://networkupstools.org/docs/man/ups.conf.html)

Stage and validate the secondary configuration and guest stop policy before production enrollment. Rollback shuts down pve01's guests and disables production autostart before removing its NUT enrollment and source allowances; minis retains its short shutdown timing throughout.

The UPS currently reports 38% load and approximately 19 minutes runtime before adding this machine. Repeat measurements under the combined load; this estimate is not a shutdown guarantee.

Keep canonical configuration and deployment runbooks in this repository, with per-host directories under `host/`. Use attended, idempotent deployment and drift checks; Flux continues managing the existing Kubernetes components. Store secrets as SOPS ciphertext and deploy only the required configuration subset, never the checkout or age private key.

Update the architecture's "no hypervisor" decision to apply specifically to minis, and record pve01 as the deliberate VM-host exception.

## 5. Rollout and acceptance gates

1. **Hardware and bootstrap:** verify disk identities and health, memory, virtualization, actual onboard NIC chipset, tagged networking, cooling, and console recovery. Confirm addresses and UDM port availability. Install and validate host firewall, time synchronization, and NUT before production guests.
2. **Networking appliance:** test NTP from all three client VLANs, denied SSH on other interfaces, denied forwarding, restricted egress, cold boot, and upstream loss. Confirm bastion and camera NTP still work with pve01 powered off.
3. **Monitoring:** test direct and DNS-based probes, independent firing/resolved Pushover notifications, and each missing-heartbeat alert. Stop either monitoring stack while host NUT remains available and verify the other remains useful. Separately test loss of minis NUT through pve01 shutdown and expiry of its external heartbeat. Confirm monitoring UIs remain accessible without minis ingress while pve01 is running.
4. **Storage and replicas:** fill scratch and separately simulate replica ENOSPC. Test concurrent uploads/prune, failed maintenance, disappearing source mounts, SSH restriction escapes, interrupted transfers, expired/overflowing snapshots, clock changes, and retention. Using disposable storage, crash the receiver before and after publication, receipt persistence, and retention rotation; inject file/directory flush failures as well as write failures. Require that acknowledged generations survive restart and verify, incomplete generations never advance freshness, and replayed receipts cannot release the wrong source snapshot. Restore from a retained generation after source-side deletion.
5. **Host recovery and power:** restore all four boot backups onto isolated networks, recover configuration from both minis and B2, reattach preserved data disks without formatting, and recreate excluded disposable disks. Test mains loss/recovery, NUT communication loss, maintenance-override expiry, and unattended reboot. Prove the normal two-minute on-battery shutdown path with all four guests initially running and adequate measured battery margin. Exercise slow and stuck guests, an active VM backup, immediate secondary disconnect, and loss of the NUT connection both just before FSD (last status online) and during shutdown. Use isolated NUT fixtures and disposable guest state to exercise urgent FSD without the early-shutdown advantage; confirm minis retains its short delay even if pve01 cannot finish. Record forced stops or interrupted guests as recovery cases, not graceful-shutdown passes. Validate restart, retained-generation checks, and restoration after an interrupted replica transfer using disposable fixtures. Then perform an attended end-to-end normal power-loss/cutoff drill with protected production state. Record the event timeline and measured battery margin, prove minis's native low-battery handling and late cutoff ordering, and require pve01's filesystems to be quiescent before output loss in the normal early-shutdown drill. Production enrollment remains blocked until these gates pass.

The host-backup gate must also exercise failed retrieval followed by another scheduled and pre-upgrade capture, concurrent capture requests, missing staging mounts, insufficient staging space, ingestion/read-back checksum failure, lost and mismatched acknowledgments, and restart during cleanup. Confirm that completed unacknowledged archives survive, capture remains bounded, and retries are idempotent. Simulate minis unavailability and separately B2 unavailability: only verified local ingestion releases staging, pending off-site copies remain pinned on minis across restart and prune, and repository capacity pressure fails without losing pending copies. Verify all failure, never-successful, and freshness alerts, then recover and drain both queues.

The power gate also requires a communication-loss shutdown with UPS output continuously powered, followed by restored communication and attended manual power-on. Confirm orderly shutdown and recovery of the configured guest startup order and services; automatic restart is not a pass condition for this scenario.

Enable recurring jobs only after their restore and failure gates pass. Observe for seven days, including a weekly VM backup and scheduled repository maintenance. Close the deployment only when replica freshness, external alerts, storage headroom, and Frigate latency remain acceptable under concurrent load.
