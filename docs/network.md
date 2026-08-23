# 🏠 Home Network Design & Deployment Plan

**Hardware Infrastructure:**
* UniFi UDM Pro
* Cisco Catalyst WS-C3850-48P (Cisco IOS XE Software, Version 16.12.14)
* Dell Wyse 5070 management bastion (OpenBSD 7.9)
* UniFi U7 Pro WAP
* Dual WAN (AT&T + Spectrum)

> **Implementation status:** the topology, Catalyst configuration, and isolated camera
> path are substantially deployed, but the numbered UDM firewall policy below is the
> approved target design and is still pending implementation and validation. Statements
> in the firewall matrix describe intended end state, not current enforcement.
> The OpenBSD bastion host, `Gi1/0/5` trunk stanza, DNS record, and Rule 940
> cutover are likewise committed target state but not yet deployed; the
> port remains access VLAN 30 until the attended bastion runbook reaches its
> trunk-cutover step.

---

## Canonical Invariants

These are the non-negotiable implementation rules for both human operators and AI agents. If any later configuration appears to conflict with these, the invariant wins unless this section is deliberately changed.

* The UDM Pro is the only routed gateway for VLANs 10, 20, 30, 60, and 80.
* The Cisco Catalyst remains Layer 2 only. Do not enable `ip routing`; its VLAN 10 SVI is for switch management only.
* VLAN 105 never reaches the UDM and is never added to the UDM/Catalyst trunk.
* VLAN 99 is L2-only blackhole/native VLAN parking. It has no routed gateway, DHCP scope, or usable host subnet.
* The YuanLey switch path must pass 802.1Q tags unchanged. Its only intended purpose is 2.5 GbE PoE+ service for UniFi WAPs; do not attach general-purpose clients to it.
* `minis` must not bridge or NAT between its VLAN 20 server NIC and VLAN 105 camera NIC. k3s may enable kernel IP forwarding globally; the invariant is that nftables drops forwarded traffic entering or leaving `cam0`.
* In steady state, `bastion` is the sole VLAN 10 administration path. VLAN 30
  operators may reach only its SSH listener at `bastion.matrix` and use
  ProxyJump/local/SOCKS forwarding; `ryze`, `m5c`, and all other VLAN 30 clients
  are denied direct routed access to VLAN 10. Temporarily disabling Rule 940 is
  the documented network break-glass exception; direct access is intentional
  only for that recovery window.
* The dual-homed bastion is an endpoint, never a router: IPv4/IPv6 forwarding is
  disabled and it runs no bridge, NAT, routing daemon, or subnet advertisement.
  Its parent link is unnumbered; only tagged VLANs 10 and 30 have addresses.
* VLAN 20 servers are denied access into VLAN 10 by default.
* Untrusted devices default to Guest / VLAN 80 and are promoted only by justified need, split **by bandwidth**: low-bandwidth control gadgets → IoT / VLAN 60; high-bandwidth casting devices that need local access → Trusted / Fastlane VLAN 30 (the IoT SSID is 2.4 GHz-only). There is no dedicated Media VLAN — its added complexity is not currently worth it.
* Infrastructure addressing is **static-first** on VLANs 10 and 20: known devices use static IPs outside the dynamic DHCP pool, with UDM DHCP reservations serving only as fallback. Camera addressing is the deliberate exception: `minis` is static at `192.168.105.1`, while `dnsmasq` DHCP reservations are authoritative for known cameras in `.50-.99`; `.100-.199` is the dynamic onboarding pool.
* Server/NAS links operate at 1 Gb. The `minis` NICs are 2.5GbE, but the router and switch ports they connect to are 1GbE, so those links negotiate at 1 Gb.
* VLAN 20 server internet egress remains unrestricted by design.

---

## 🧭 Design Decisions & Rationale

The choices below are deliberate and non-obvious. They are summarized here so a reader (human or agent) can understand intent without reverse-engineering it from the config. Details for each live in the relevant section further down.

| Decision | Rationale | Alternative / when to revisit |
| --- | --- | --- |
| **Dual-WAN is failover only** (AT&T primary, Spectrum idle until failover) | Keeps a stable primary IP and avoids per-session path flapping; Spectrum's asymmetric 40M upload makes it a backup, not a co-primary. | Load-balancing/WAN aggregation — revisit if sustained bandwidth demand exceeds AT&T alone. |
| **UDM Pro does all routing; Catalyst is strictly L2** | Single point for inter-VLAN routing and firewall policy; the Catalyst only switches and holds one VLAN 10 management SVI. | L3 switching on the Catalyst — revisit only if inter-VLAN throughput outgrows the UDM. |
| **WAP uplink uses Native/Untagged VLAN 10** (mgmt) + tagged 30/60/80 | Simpler AP adoption/recovery across the *unmanaged* YuanLey switch; acceptable because the YuanLey exists only to provide 2.5 GbE PoE+ for WAPs, not general client access. | Stricter Native VLAN 99 + tagged mgmt VLAN 10 — revisit if the WAP path moves to a managed switch or if non-WAP devices must be attached there. |
| **WAP uplinks via a dedicated UPS-backed YuanLey 2.5G switch**, not the Catalyst | Wi-Fi 7 throughput can exceed 1 Gb; the Catalyst's 1G access ports would bottleneck the U7 Pro's 2.5G uplink. The YuanLey is also on a UPS, so Wi-Fi keeps working through a power outage that would take the Catalyst down. | Power the AP directly from the Catalyst (UPOE) — revisit only if the AP shares the Catalyst's UPS and a 1G uplink becomes acceptable. |
| **Native VLAN 99 is an empty blackhole** on the Catalyst trunk | Untagged/rogue frames land in an empty, unrouted VLAN instead of a live data VLAN. | — |
| **Camera VLAN 105 is fully isolated** (no gateway, off-trunk, reached only via the dual-homed `minis` NVR NIC, no bridging) | Cameras can't reach the internet or any other VLAN; only the NVR sees them. Strong containment for untrusted camera firmware. | — |
| **IoT (VLAN 60) gets full outbound internet** | Most IoT devices depend on vendor cloud to function. Unsolicited inbound and lateral movement remain blocked. | Block/allowlist egress — revisit if you want to cut off chatty or untrusted devices. |
| **VLAN 10 temporarily has no designated NTP source** | Morpheus was retired on 2026-08-10, so its DHCP option 42 advertisement and VLAN 10 → Morpheus UDP/123 exception are removed rather than pointing clients at a powered-off host. Camera NTP on `minis` is separate and remains active. | Select a replacement internal NTP source before restoring DHCP option 42 or adding a new firewall exception. |
| **SLZB-MRW10U is temporarily on Trusted VLAN 30; target placement is IoT VLAN 60** | The dual-radio coordinator is a network appliance rather than a trusted general-purpose client. Its consumers use the fixed `slzb-mrw10u.iot.matrix` name and TCP ports `6638` (Z-Wave) and `7638` (Zigbee), so it does not require mDNS reflection. | Before moving it, record its current IP/MAC, assign a stable VLAN 60 address, update the existing UDM A record, and stage the narrow VLAN 20 → VLAN 60 allow rule below. |
| **Static-first addressing on VLAN 20 servers and VLAN 10 management; authoritative `dnsmasq` reservations for VLAN 105 cameras** | Servers and management devices retain static addresses with UDM reservations as fallback. Cameras receive their stable `.50-.99` addresses from the only DHCP server on the isolated segment, avoiding per-camera static-IP drift while keeping Frigate targets deterministic. | — |
| **General wired ports default to Trusted VLAN 30** | Convenience: anything plugged in just works. Physical access to trusted Ethernet is treated as outside the threat model. | Park unused ports in VLAN 99 — revisit if the physical-access assumption changes. |
| **In steady state, Admin (VLAN 10) is reachable only through the dedicated OpenBSD `bastion`** | A disposable, key-only SSH host provides ProxyJump/local/SOCKS forwarding without giving any workstation a persistent routed firewall exception or storing operator private keys or device credentials. Its unique local account passwords are retained only for console bootstrap and `doas`. Temporarily disabling Rule 940 is the authorized network break-glass procedure. | If Proxmox is reconsidered, terminate VLANs on a VLAN-aware bridge and present two hypervisor-tagged access vNICs; do not pass the trunk into the guest. |
| **VLAN 20 servers have unrestricted internet egress** | Servers, NAS workloads, package managers, containers, and update tooling are expected to need normal outbound internet. | Per-host or service-specific egress allowlists — revisit only if a server is exposed to meaningfully untrusted workloads. |
| **Trusted SSID is 5/6 GHz only** | Maximizes performance for trusted devices. | Add 2.4 GHz to Trusted (or a Trusted-2.4 SSID) if a trusted device is 2.4-only or needs the range. |
| **Untrusted devices start on Guest by default** | New/unknown devices get internet-only with client isolation; promotion requires a justified need. Promote **by bandwidth**: low-bandwidth control gadgets → IoT VLAN 60; high-bandwidth casting devices (TVs/streamers) that need local access → Trusted VLAN 30, since the IoT SSID is 2.4 GHz-only. | A dedicated Media VLAN/SSID was considered and rejected because the added rules and SSID complexity are not worth it for the current environment. Revisit only if the trusted segment becomes too broad. |

---

## 🗺️ Network Topology

### Overview (Logical / VLAN View)

*Shows how devices map to VLANs and the routing/trunk relationships. For exact physical ports and media types see the Detail view below — the two are consistent, not conflicting.*

```text
[AT&T Fiber] ─────┐
                   ├──► [UDM Pro · gateway/firewall · 10.137.10.1]
[Spectrum backup] ─┘                         │
                                            ├── V30 ──► [ryze · 10.137.30.6]
                                            ├── V20 ──► [morpheus · 10.137.20.2 · cold]
                                            ├── V20 ──► [minis · 10.137.20.5 · server]
                                            │
                                            ├── 10G trunk ──► [Catalyst 3850 · L2 only · 10.137.10.2]
                                            │                       │
                                            │                       ├── Gi1/0/1-4  · V10 access ──► [IPMI/IPKVM]
                                            │                       ├── Gi1/0/5    · V10/V30 tagged; V99 native ──► [bastion]
                                            │                       ├── Gi1/0/6-36 · V30 access ──► [wired LAN]
                                            │                       ├── Gi1/0/37-47 · V105 access ──► [security cameras]
                                            │                       └── Gi1/0/48   · V105 access ──► [minis camera NIC]
                                            │                           └── local NVR only; no bridge
                                            │
                                            └── WAP trunk ──► [YuanLey PoE+] ──► [U7 Pro · 10.137.10.7]
                                                └── Native V10; tagged V30/V60/V80
```

### Detail (Physical / Port View)

*Shows physical ports, media types (RJ45 / DAC / fiber), and per-port VLAN tagging. It mirrors the logical Overview above at the port level.*

```text
EXTERNAL WAN
  [AT&T fiber · primary · 1G symmetric] ── RJ45 ──► UDM Port 9 (WAN1)
  [Spectrum · failover · 1G/40M]         ── RJ45 ──► UDM Port 8 (WAN2)

UDM PRO · 10.137.10.1
  Port 1  ── RJ45 · access V30 ───────────────────► [ryze · 10.137.30.6]
  Port 2  ── RJ45 · access V20 ───────────────────► [morpheus · 10.137.20.2 · off]
  Port 3  ── RJ45 · access V20 ───────────────────► [minis server NIC · 10.137.20.5]
  Port 11 ── 10G SFP+ fiber · WAP trunk ───────────► [YuanLey unmanaged switch]
  │   └── 2.5G PoE+ ──► [U7 Pro · 10.137.10.7]
  │       └── Native V10; tagged V30/V60/V80
  │
  Port 10 ── 10G SFP+ DAC · 802.1Q trunk ─────────► [Catalyst Te1/1/4]
  │   └── Native V99; tagged V10/V20/V30/V60/V80; V105 excluded
  │
  └─ CATALYST 3850 · 10.137.10.2 · L2 ONLY
       Gi1/0/1-4  ── 1G RJ45 · access V10 ─────────► [IPMI/IPKVM]
       Gi1/0/5    ── 1G RJ45 · restricted trunk ───► [OpenBSD bastion]
       │   └── Native V99; tagged V10/V30 only
       Gi1/0/6-36 ── 1G RJ45 · access V30 ─────────► [wired clients]
       Gi1/0/37-47 ── 1G RJ45 · protected V105 ────► [security cameras]
       Gi1/0/48   ── 1G RJ45 · access V105 ─────────► [minis camera NIC · 192.168.105.1]
           └── Local NVR/NTP path; no bridging
```

### WAP Uplink Design Decision

The UniFi U7 Pro is managed on VLAN 10 using Native/Untagged traffic across UDM Port 11 and the unmanaged YuanLey PoE switch. SSID client traffic is tagged as VLAN 30, VLAN 60, or VLAN 80. The YuanLey switch is not a general-purpose access switch; its only intended role is providing 2.5 GbE PoE+ service to WAPs.

```text
UDM Port 11 → YuanLey unmanaged PoE switch → UniFi U7 Pro
Native/Untagged: VLAN 10 Admin / Management
Tagged: VLAN 30 Trusted / Fastlane, VLAN 60 IoT, VLAN 80 Guest
```

This is intentionally chosen over the stricter alternative of Native VLAN 99 plus Tagged VLAN 10 management. Native VLAN 10 is more forgiving for AP adoption/recovery and is acceptable because the YuanLey is dedicated to WAP uplinks. If non-WAP devices ever need to attach there, move the path to a managed 2.5 GbE PoE switch or revisit the native VLAN design first.

---

## 📊 VLAN & Subnet Architecture

The Cisco Catalyst 3850 acts **strictly as an L2 switch**. All inter-VLAN routing is handled entirely by the UDM Pro gateway. The Catalyst holds a single SVI on VLAN 10 (`10.137.10.2`) purely as a management interface — this is a host IP, not routing. The uplink trunk carries tagged VLANs 10, 20, 30, 60, and 80 plus the untagged native VLAN 99 (blackhole); VLAN 105 is deliberately excluded. Today VLAN 10 (management/IPMI/IPKVM), VLAN 30 (wired client ports), and VLAN 105 (local cameras) are assigned to Catalyst access ports; 20/60/80 are trunked for future flexibility.

| VLAN | Network Name | Subnet | Gateway | DHCP Range | Intended Purpose & Security Rules |
| --- | --- | --- | --- | --- | --- |
| **10** | Admin / Management | `10.137.10.0/24` | `10.137.10.1` | `10.137.10.100-10.137.10.199` fallback/onboarding | **Network gear, server IPMI/IPKVM, and management interfaces only.** Static-first addressing; tightly scoped access and egress. See VLAN 10 policy details below. |
| **20** | Servers | `10.137.20.0/24` | `10.137.20.1` | `10.137.20.100-10.137.20.199` reservation fallback | Linux servers, NAS, NVR server interface, Docker hosts. Static-first addressing, with UDM DHCP reservations mapping each known host MAC to its intended stable IP if the host requests a lease. Static addresses must live outside the dynamic DHCP pool. VLAN 20 has unrestricted outbound internet by design. |
| **30** | Trusted / Fastlane | `10.137.30.0/24` | `10.137.30.1` | `10.137.30.100-10.137.30.199` | Trusted personal workstations, laptops, phones, desktops, and explicitly trusted streamers. Primary high-performance home LAN. |
| **60** | IoT / Home Integrated | `10.137.60.0/24` | `10.137.60.1` | `10.137.60.100-10.137.60.199` | Untrusted, **low-bandwidth** home devices that need limited local integration: smart plugs, bulbs, sensors, speakers, small appliances. Devices promoted from Guest land here *only* if they are low-bandwidth control gadgets; a high-bandwidth casting device (smart TV, streaming box) that needs local access is promoted to **Trusted / Fastlane VLAN 30** instead, because the IoT SSID is 2.4 GHz-only and would starve it. |
| **80** | Guest / Internet Only | `10.137.80.0/24` | `10.137.80.1` | `10.137.80.100-10.137.80.199` | Visitors, corporate laptops, cheap TVs, consoles, streaming boxes, and other untrusted devices by default. Complete client isolation enabled. Internet access only. |
| **99** | Blackhole | N/A - no L3 interface | — | **None** | **Native Untagged VLAN Parking.** Kept entirely empty to isolate untagged trunk traffic. L2 parking only; no routed UDM interface and no usable host subnet. |
| **105** | Cameras | `192.168.105.0/24` | No routed gateway; DHCP advertises `.1` as a dead end for firmware compatibility | Known-camera reservations: `192.168.105.50-192.168.105.99`; unknown-device pool: `192.168.105.100-192.168.105.199` | **Locally isolated camera segment.** No UDM gateway exists and VLAN 105 is not extended to the UDM trunk. Reachable only by the dedicated `minis` NVR NIC; no bridging or NAT is allowed, and nftables drops forwarded traffic entering or leaving `cam0` even after k3s enables kernel IP forwarding. `minis` is the segment's sole DHCP server; its `dnsmasq` MAC reservations are authoritative for known camera addresses. DHCP advertises `192.168.105.1` as the router only for camera firmware compatibility, while nftables makes that route a dead end for LAN/internet forwarding. DNS is intentionally disabled (`port=0`) because a resolver would create an exfiltration channel. The off-scheme addressing is intentional: it makes the isolated, never-routed segment visually distinct from the site-wide `10.137.x` plan. |

### VLAN 10 Policy Details

* **Addressing:** All known VLAN 10 infrastructure should have static IPs configured outside the dynamic DHCP pool. UDM DHCP reservations are fallback/onboarding only.
* **Internet egress:** VLAN 10 has no general-purpose internet access. Allow only tightly scoped infrastructure egress for the UDM Pro, UniFi U7 Pro, approved IPMI/IPKVM devices, and other approved management infrastructure.
* **DNS:** VLAN 10 clients use the UDM gateway (`10.137.10.1`) as their DNS resolver. Do not open direct internet DNS egress from VLAN 10 clients.
* **NTP:** VLAN 10 temporarily has no designated NTP source. Morpheus no longer serves NTP, and its UniFi DHCP option 42 advertisement and UDP/123 firewall exception are retired. Select a replacement internal source before advertising NTP again. Camera NTP remains independently served by `minis` on the isolated camera segment.
* **UniFi cloud/controller services:** Keep any required UniFi cloud, controller, firmware, or update exceptions scoped to the UDM Pro and UniFi U7 Pro unless a specific additional VLAN 10 device needs them. Identify the exact service requirements during implementation rather than granting blanket VLAN 10 internet access.
* **Management access:** Rule 940 unconditionally denies Trusted/VLAN 30 routed
  access to VLAN 10. Operators first SSH to `bastion.matrix` on VLAN 30; sessions
  originated by the bastion use its directly connected `10.137.10.8` interface.
  "Unconditional" means the enabled rule has no per-client exceptions; the
  documented network break-glass procedure temporarily disables the whole rule.
* **Jumpbox rule:** `ryze`, `m5c`, and other VLAN 30 clients use the dedicated
  bastion for network-gear administration. Direct VLAN 20 server administration
  remains allowed by the separate Trusted-to-Servers policy.
* **Remote management:** Tailnet routes are unchanged. Advertising VLAN 10 or the
  bastion as a Tailnet subnet route is explicitly out of scope.

> **Operational stance:** This is a home network with convenience-weighted physical access assumptions. General-purpose wired ports remain on VLAN 30 for ease of use. If someone already has physical access to plug into trusted Ethernet, that is considered outside the main threat model.

---

## 🔒 Planned Firewall & Traffic Flow Matrix

The UDM will follow a **Default Deny** inter-VLAN policy once the pending rules are deployed. Traffic will be explicitly blocked unless defined below, with stateful inspection allowing legitimate return traffic. Any omitted inter-VLAN flow will be denied by default, including Servers/VLAN 20 → Admin/VLAN 10. **WAN/internet egress is a separate axis from inter-VLAN policy:** the target design allows outbound internet by default for VLANs 20, 30, 60, and 80, and denies it for VLAN 10 except for tightly scoped infrastructure exceptions.

Rule order matters during implementation. In UniFi, place specific allow rules above broader drop rules. Keep inter-VLAN rules in the LAN/local traffic policy area and keep WAN/internet egress policy separate.

### LAN / Inter-VLAN Rules

| Rule | Target enabled | Name | Action | Protocol | Source | Destination | Destination Port | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 110 | Yes | Allow Trusted to Servers | Allow | All | Trusted / Fastlane `VLAN 30` | Servers `VLAN 20` | Any | Broad trusted-client access to internal services and direct server administration. |
| 130+ | As needed | Allow selected Trusted to IoT services | Allow | Service-specific | Trusted / Fastlane `VLAN 30` | IoT / Home Integrated `VLAN 60` | Service-specific | Add only for justified setup, control, casting, or device-management flows. |
| 140 | Yes after coordinator migration | Allow `minis` to SLZB-MRW10U | Allow | TCP | `minis` `10.137.20.5` | SLZB-MRW10U stable address on IoT `VLAN 60` (TBD) | `6638`, `7638` | Required by Z-Wave JS UI, Zigbee2MQTT, and the coordinator TCP probe after the appliance moves from VLAN 30. Stage above Rules 910/920 and verify the UDM observes pod egress as the `minis` node address. No mDNS reflector is required or intended. |
| 141+ | As needed | Allow selected Servers to IoT services | Allow | Service-specific | Servers `VLAN 20` | IoT / Home Integrated `VLAN 60` | Service-specific | Add only for Home Assistant or other server-driven device-control flows. |
| 150+ | As needed | Allow selected IoT to Server services | Allow | Service-specific | IoT / Home Integrated `VLAN 60` | Servers `VLAN 20` | Service-specific | Add only for intentionally exposed services such as Home Assistant, Plex, or similar local endpoints. |
| 900 | Yes | Drop Guest to internal networks | Drop | All | Guest / Internet Only `VLAN 80` | Internal VLANs / RFC1918 | Any | Guest is internet-only with no casting/local discovery. |
| 910 | Yes | Drop IoT to internal networks | Drop | All | IoT / Home Integrated `VLAN 60` | Internal VLANs / RFC1918 | Any | Blocks unsolicited IoT lateral movement except explicit allow rules above. |
| 920 | Yes | Drop Servers to internal networks | Drop | All | Servers `VLAN 20` | Internal VLANs / RFC1918 | Any | Servers are denied access into management and other internal client VLANs by default. Place any justified server-to-IoT allows above this rule. |
| 930 | Yes | Drop Admin to internal networks | Drop | All | Admin / Management `VLAN 10` | Internal VLANs / RFC1918 | Any | No VLAN 10 → VLAN 20 NTP exception remains after Morpheus retirement. |
| 940 | Yes | Drop Trusted to Admin | Drop | All | Trusted / Fastlane `VLAN 30` | Admin / Management `VLAN 10` | Any | Steady-state rule with no `ryze`, `m5c`, or other host exception. Operators reach `bastion.matrix:22` within VLAN 30, then originate management sessions from the bastion's directly connected VLAN 10 interface. Temporarily disable the whole rule only for the documented network break-glass window. |
| 950 | Yes | Drop Trusted to IoT | Drop | All | Trusted / Fastlane `VLAN 30` | IoT / Home Integrated `VLAN 60` | Any | Placed below Rule 130+ so only justified Trusted-to-IoT exceptions are allowed. |
| 960 | Yes | Drop internal networks to Guest | Drop | All | Internal VLANs `10/20/30/60` | Guest / Internet Only `VLAN 80` | Any | Net-new effect is blocking **Trusted/VLAN 30 → Guest** — Trusted has no other blanket internal-drop rule, while Rules 910/920/930 already drop IoT/Servers/Admin to the Guest subnet (it is RFC1918). Together these make Guest unreachable from every internal VLAN. |

### WAN / Internet Egress Policy

| Rule | Target enabled | Name | Action | Protocol | Source | Destination | Destination Port | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1000 | Yes | Allow Servers to Internet | Allow | All | Servers `VLAN 20` | Internet | Any | VLAN 20 egress is intentionally unrestricted for updates, containers, package managers, NAS workloads, and services. |
| 1010 | Yes | Allow Trusted to Internet | Allow | All | Trusted / Fastlane `VLAN 30` | Internet | Any | Normal client internet access. |
| 1020 | Yes | Allow IoT to Internet | Allow | All | IoT / Home Integrated `VLAN 60` | Internet | Any | Full outbound internet permitted; do not block external DNS/DoH by design. |
| 1030 | Yes | Allow Guest to Internet | Allow | All | Guest / Internet Only `VLAN 80` | Internet | Any | Internet-only by definition; local access remains blocked by LAN rules and client isolation. |
| 1040 | Yes | Allow Admin infrastructure egress | Allow | Service-specific | UDM Pro / UniFi U7 Pro / approved VLAN 10 infrastructure, including approved IPMI/IPKVM devices | Internet | Firmware/update and UniFi cloud/controller services as needed | VLAN 10 clients use the UDM as DNS resolver; do not allow direct internet DNS from VLAN 10 clients. No per-device internet NTP egress is open; a replacement internal NTP source remains deferred. |
| 1990 | Yes | Drop Admin general Internet | Drop | All | Admin / Management `VLAN 10` | Internet | Any | Other management devices are updated manually/on demand. |
| N/A | N/A | Cameras to Internet | N/A | N/A | Cameras `VLAN 105` | Internet | N/A | Physically isolated, gateway-less segment. No routed path to the WAN exists. |

### 📶 SSID & Device Placement Policy

The wireless design uses **three active SSIDs**. New untrusted devices start on Guest by default and are promoted only when they need justified local-home access.

| SSID | Bands | VLAN | Devices | Policy |
| --- | --- | --- | --- | --- |
| **Trusted / Fastlane** | 5 GHz + 6 GHz | **30** | Phones, laptops, desktops, trusted streamers | High-performance trusted LAN. Devices here can access internal services according to firewall policy. |
| **IoT** | 2.4 GHz only | **60** | Smart plugs, bulbs, sensors, speakers, appliances | For untrusted but home-integrated devices that need compatibility and limited local control. |
| **Guest** | 2.4 GHz + 5 GHz | **80** | Visitors, corporate laptops, cheap TVs, consoles, streaming boxes by default | Internet-only with client isolation. No casting/local discovery. Default landing zone for devices that do not need local access. |

> **Design intent:** Trusted / Fastlane is intentionally 5 GHz + 6 GHz only (no 2.4 GHz) to keep it high-performance. This assumes no *trusted* device is 2.4 GHz-only or needs 2.4 GHz for range. If such a device appears, revisit by adding a 2.4 GHz radio to the Trusted SSID or standing up a dedicated Trusted-2.4 SSID on VLAN 30.

### 🎥 Local Camera Isolation (Catalyst Cisco IOS Config)

VLAN 105 is a locally isolated camera segment. It has no UDM gateway, is excluded from the UDM/Catalyst trunk, and is reachable only through the dedicated `minis` NVR camera-side NIC. The `minis` host is dual-homed, but bridging/NAT between the server-side NIC and camera-side NIC is not allowed; nftables drops forwarded traffic entering or leaving `cam0`, including after k3s enables kernel IP forwarding.

Because there is no routed gateway on this segment, the cameras have **no path to the internet** (no firmware phone-home, no remote access — intentional). Cameras use DHCP, with authoritative `dnsmasq` MAC-to-IP reservations in `192.168.105.50-99`; unknown devices temporarily land in `.100-.199` for onboarding. The `minis` camera-side NIC at `192.168.105.1` is the **NVR/NTP host itself, not a forwarding gateway**. DHCP advertises it as the router because some camera firmware otherwise renews continuously, but nftables makes that route a dead end. Cameras should use `192.168.105.1` as their local NTP server because no external NTP is reachable.

Camera ports use **Switchport Protected** profiles. Cameras can talk to the NVR server port, but cannot communicate with each other.

**Viewing the cameras:** because VLAN 105 is otherwise unreachable, the only sanctioned way to watch the cameras is through Frigate's web UI hosted on `minis` via its VLAN 20 server-side interface (`10.137.20.5`). Trusted clients reach that UI because the firewall allows VLAN 30 → VLAN 20; `minis` reads the camera feeds on its isolated VLAN 105 NIC and never bridges the two segments.

* **Camera Ports (Gi1/0/37 - 47):** This 11-port range is reserved camera capacity; only one camera is deployed today, so the remaining ports are pre-provisioned but unused.
```ios
interface range GigabitEthernet1/0/37-47
 switchport mode access
 switchport access vlan 105
 switchport protected
 switchport block unicast
 switchport block multicast
 spanning-tree portfast
 spanning-tree bpduguard enable
```
`switchport protected` stops the camera ports from talking to each other directly; `switchport block unicast` and `switchport block multicast` additionally stop unknown-unicast and multicast/flood frames from leaking between them. The NVR ingestion port (Gi1/0/48) deliberately omits all three so cameras can reach it.

* **NVR Camera-Side Interface (Gi1/0/48):**
```ios
interface GigabitEthernet1/0/48
 switchport mode access
 switchport access vlan 105
 spanning-tree portfast
 spanning-tree bpduguard enable
 ! Note: NO 'switchport protected' statement here so cameras can communicate with this port.
```

---

### IPMI / IPKVM Port Allocation

Server out-of-band management devices belong on VLAN 10, not VLAN 20. Reserve a small Catalyst port block for IPMI/IPKVM access devices so they are physically and logically distinct from general-purpose wired client ports.

* **IPMI/IPKVM Ports (Gi1/0/1 - 4):** Reserved for server management controllers, IPKVMs, and similar out-of-band management devices. Known devices should use static IPs outside the VLAN 10 dynamic DHCP pool; DHCP remains available only as fallback/onboarding.
```ios
interface range GigabitEthernet1/0/1-4
 switchport mode access
 switchport access vlan 10
 spanning-tree portfast
 spanning-tree bpduguard enable
```

### Management bastion

The Wyse 5070 runs a base-only, bare-metal OpenBSD 7.9 install. Catalyst
`Gi1/0/5` is a restricted trunk with native VLAN 99 and allowed VLANs exactly
`10,30,99`. The physical interface is unnumbered; `vlan30` owns
`10.137.30.8/24` with the sole default route and SSH listener, while `vlan10`
owns directly connected `10.137.10.8/24` with no gateway or listener. IPv6 and
parent IPv4 autoconfiguration are disabled, `dhcpleased` is stopped, and both
forwarding sysctls are zero. PF permits key-only operator SSH from VLAN 30, DNS
through the VLAN 30 gateway, NTP only to Cloudflare's two documented IPv4
anycast endpoints, HTTPS egress for the `_ntp` constraint process, HTTP(S)
egress only for the `_file` and `_syspatch` base-system fetch users, and
bastion-originated management traffic on VLAN 10. PF states are interface-bound,
so established traffic cannot match on the other VLAN before interface-specific
filtering. Operator-owned SSH forwarding sockets therefore cannot use the host
as an internet web proxy. It creates no NAT, bridge, or routed path.

The host stores no operator private keys, device credentials, browser state, or
application data. BIOS auto-power-on and an unencrypted system disk favor
unattended recovery; the BIOS administrator password remains only in the
password manager. Configuration, deployment tests, ProxyJump/local/SOCKS
examples, console recovery, and switch/UDM rollback are canonical in
[`runbooks/bastion/README.md`](../runbooks/bastion/README.md). The actual wired
interface and MAC must be discovered by that runbook rather than assumed.
Steady-state break-glass does not depend on the bastion: a VLAN 30 operator can
use the UDM UI at `https://10.137.30.1` to disable Rule 940 and restore the
pre-cutover routed-management behavior, or use the Catalyst's deliberately
unauthenticated physical console to return `Gi1/0/5` to access VLAN 30 for a
rebuild.

If this role later moves to Proxmox, use a VLAN-aware bridge with two
hypervisor-tagged vNICs presented untagged to the guest. Do not pass the trunk
through to the VM; VLAN policy should stay outside the guest.

## 🖥️ Physical Hardware & Client Inventory

### Infrastructure Equipment

* **UniFi Dream Machine Pro (`10.137.10.1`)**
  * *Roles:* Main WAN Router, Firewall, IDS/IPS Engine, UniFi Controller.
  * *SFP+ WAN reassignment:* Spectrum runs on RJ45 Port 8 (not the default SFP+ WAN), which frees the single SFP+ WAN port (Port 10) for LAN — so both SFP+ ports now serve LAN. Confirmed working in the current setup; depends on UniFi OS support for reassigning the SFP+ WAN port to LAN.
  * *Port Allocations:*

| Port | Media | Role | VLAN Config | Connected Device |
| --- | --- | --- | --- | --- |
| **Port 1** | 1G RJ45 LAN | Client | Native/Access VLAN 30 | `ryze` desktop (`10.137.30.6`) |
| **Port 2** | 1G RJ45 LAN | Client | Native/Access VLAN 20 | `morpheus` cold spare (`10.137.20.2`; powered off, cable retained) |
| **Port 3** | 1G RJ45 LAN | Client | Native/Access VLAN 20 | `minis` server NIC (`10.137.20.5`) |
| **Ports 4–7** | 1G RJ45 LAN | Unused | — | Available |
| **Port 8** | 1G RJ45 | WAN2 | — | Spectrum (failover) |
| **Port 9** | 1G RJ45 | WAN1 | — | AT&T fiber (primary) |
| **Port 10** | 10G SFP+ | LAN trunk (reassigned from default SFP+ WAN) | Native/Untagged VLAN 99; Tagged 10/20/30/60/80 | Catalyst `Te1/1/4` via 10G DAC |
| **Port 11** | 10G SFP+ LAN | WAP uplink trunk | Native/Untagged VLAN 10; Tagged 30/60/80 | YuanLey switch → U7 Pro (10G SFP+ fiber) |

* **Cisco Catalyst WS-C3850-48P (`10.137.10.2`)**
  * *Roles:* Layer 2 Distribution Switch, PoE Core. Holds a single management SVI on VLAN 10 (`10.137.10.2`) — a host IP, not routing.
  * *Software:* Cisco IOS XE Software, Version 16.12.14.
  * *Uplink:* Port `Te1/1/4` via 10G DAC → UDM Port 10. VLAN 99 is included in the allowed list so the trunk carries its own native VLAN; VLAN 105 is excluded.
  * *Status:* **Installed and operational** — this 10G DAC trunk to the UDM is already up; the optics/cabling are validated in place.
  * *Port Allocations:*

| Port(s) | Media | Mode | VLAN | Purpose | Key Config |
| --- | --- | --- | --- | --- | --- |
| **`Te1/1/4`** | 10G SFP+ (DAC) | 802.1Q Trunk | Native 99; allowed `10,20,30,60,80,99` | Uplink to UDM Port 10 | VLAN 105 excluded from trunk |
| **`Gi1/0/1–4`** | 1G RJ45 | Access | VLAN 10 | IPMI/IPKVM out-of-band mgmt | PortFast + BPDUguard |
| **`Gi1/0/5`** | 1G RJ45 (UPOE) | 802.1Q Trunk | Native 99; allowed exactly `10,30,99` | Wyse OpenBSD bastion | `nonegotiate`, PortFast trunk, BPDUguard |
| **`Gi1/0/6–36`** | 1G RJ45 (UPOE) | Access | VLAN 30 | General wired clients | PortFast / BPDUguard |
| **`Gi1/0/37–47`** | 1G RJ45 | Access | VLAN 105 | Camera deployment (11 ports; 1 used today) | `switchport protected` + `block unicast`/`block multicast`, PortFast, BPDUguard |
| **`Gi1/0/48`** | 1G RJ45 | Access | VLAN 105 | `minis` NVR camera-side ingestion | **No** `switchport protected`; PortFast, BPDUguard |

* **Dell Wyse 5070 management bastion (`bastion`)**
  * *Roles:* Dedicated, disposable SSH jump host and the sole operator entry path
    to Admin/VLAN 10; it is an endpoint, not a router, bridge, NAT gateway, VPN
    endpoint, or Tailnet subnet router.
  * *Software:* Base-only, bare-metal OpenBSD 7.9 amd64.
  * *Connection:* Its sole enabled wired NIC connects to Catalyst `Gi1/0/5`, a
    restricted trunk with native VLAN 99 and tagged VLANs exactly 10 and 30.
  * *Addressing:* The physical parent is unnumbered. Tagged `vlan30` owns
    `10.137.30.8/24`, the only SSH listener, and the sole default route through
    `10.137.30.1`; tagged `vlan10` owns `10.137.10.8/24` for bastion-originated
    management sessions only. The wired MAC remains TBD until guarded preflight.
  * *Status:* **Committed target state, not yet deployed.** Catalyst `Gi1/0/5`
    remains access VLAN 30 until the attended bastion runbook reaches trunk
    cutover.

* **YuanLey 6-Port 2.5G PoE Switch (Unmanaged)**
  * *Roles:* Dedicated power/data extension for the wireless access point.
  * *Why a separate switch instead of the Catalyst:* (1) Wi-Fi 7 throughput can exceed 1 Gb, so the UniFi U7 Pro's 2.5G uplink would be bottlenecked by the Catalyst's 1G access ports; the YuanLey's 2.5G ports preserve full AP bandwidth. (2) The YuanLey is on a UPS, so Wi-Fi stays up during a power outage that would take the Catalyst offline.
  * *Uplink:* 10G SFP+ fiber link to UDM Port 11, using a matched SFP+ transceiver at each end (one in the UDM SFP+ cage, one in the YuanLey SFP+ cage). The YuanLey's PoE access ports are 2.5G; only the SFP+ uplink runs at 10G. UDM Port 11 uses Native/Untagged VLAN 10 for AP management and Tagged VLANs 30/60/80 for SSID client traffic. The unmanaged switch simply passes tagged frames through to the WAP. The switch is dedicated to WAP service; do not attach general-purpose clients to its spare copper ports. **Dependency:** this path assumes the YuanLey is 802.1Q tag-transparent — it forwards tagged VLAN 30/60/80 frames without stripping or rewriting tags. If it ever strips tags, SSID client traffic falls onto the untagged native VLAN 10 (management), which is the single failure this design most wants to avoid. The SSID separation must therefore be verified after install (see the Phase 1 checklist). If verification fails, replace the YuanLey with a managed 2.5G PoE switch or temporarily move the AP to the Catalyst at 1G until the managed switch is available.
  * *Status:* **Installed and operational** — this 10G SFP+ fiber trunk to the UDM is already up; the matched transceivers are validated in place.


* **UniFi U7 Pro WAP (`10.137.10.7`)**
  * *Management:* Native/Untagged VLAN 10 on the Port 11 WAP uplink path. Configure `10.137.10.7` static-first on the device, with a UDM DHCP reservation as fallback.
  * *SSID Layout:*
    * **Trusted / Fastlane** (VLAN 30, 5 GHz + 6 GHz, WPA3)
    * **IoT** (VLAN 60, 2.4 GHz only, compatibility-first)
    * **Guest** (VLAN 80, 2.4 GHz + 5 GHz, guest isolation/client isolation, internet-only)
  * *Device onboarding policy:* untrusted TVs, consoles, streaming boxes, and similar appliances start on Guest. Promote only when local access is required and justified. When promoting, split by bandwidth: low-bandwidth control gadgets go to IoT VLAN 60; high-bandwidth casting devices (smart TVs, streaming boxes) that need local access go to Trusted / Fastlane VLAN 30, since the IoT SSID is 2.4 GHz-only.
  * *Design choice:* Native VLAN 10 is preferred over tagged management VLAN 10/native VLAN 99 because it keeps AP adoption and recovery simpler when using the unmanaged YuanLey PoE switch. The stricter tagged-management design may be reconsidered if the WAP path is moved to a managed switch later.

### MAC-to-IP Reference

Use this table when creating DHCP reservations, static host records, ISP records, and authoritative `dnsmasq` camera mappings. `TBD` means the value has not yet been recorded in this document.

| Device / Interface | VLAN | IP Address | MAC Address | Assignment |
| --- | --- | --- | --- | --- |
| UDM Pro primary / controller | 10 | `10.137.10.1` | `f4:92:bf:75:d5:a9` | Static appliance IP |
| UDM Pro WAN1 / AT&T | WAN | ISP-assigned | `f4:92:bf:75:d5:b0` | WAN interface MAC |
| UDM Pro WAN2 / Spectrum | WAN | ISP-assigned | `f4:92:bf:75:d5:b1` | WAN interface MAC |
| Cisco Catalyst management SVI | 10 | `10.137.10.2` | TBD | Static switch SVI |
| UniFi U7 Pro WAP management | 10 | `10.137.10.7` | `28:70:4e:31:17:f9` | Static-first; UDM reservation fallback |
| `bastion` tagged Admin interface | 10 | `10.137.10.8` | Wyse wired MAC: **TBD at guarded preflight** | Static; inventory-only, not an operator DNS entry point |
| `bastion` tagged Trusted interface | 30 | `10.137.30.8` | Same Wyse wired MAC: **TBD at guarded preflight** | Static; sole SSH listener and default route |
| `morpheus` cold spare | 20 | `10.137.20.2` | `b4:2e:99:33:d6:0b` | Retained static DNS and UDM reservation; powered off |
| `minis` server NIC | 20 | `10.137.20.5` | `38:05:25:35:fb:d3` | Static-first; UDM reservation fallback |
| `minis` camera-side NIC | 105 | `192.168.105.1` | `38:05:25:35:fb:d2` | Static local NVR/NTP endpoint |
| Amcrest `AMC108F5E2C2775601` | 105 | `192.168.105.50` | `a0:60:32:04:b1:3e` | Authoritative `dnsmasq` DHCP reservation; only deployed camera |
| `ryze` desktop | 30 | `10.137.30.6` | `a8:a1:59:51:47:4e` | Static or UDM DHCP reservation |
| `m5c` Wi-Fi | 30 | DHCP `10.137.30.x` | `aa:9a:b7:f2:ea:2d` | DHCP; private MAC disabled |
| SLZB-MRW10U dual-radio coordinator | 30 currently; target 60 | Current `10.137.30.x` TBD; target `10.137.60.x` TBD | TBD | Record current identity, then create a stable VLAN 60 UDM reservation before migration |

### Static DNS Records (UDM)

Create these forward (A) records on the UDM resolver. The network's local domain is `matrix`. Active records point at static-first / fixed IPs, so the names do not drift; ensure each host's UDM DHCP reservation (fallback) uses the same IP so a fallback lease cannot contradict DNS. The SLZB-MRW10U row records the one current inventory gap: its existing VLAN 30 A-record value has not yet been copied into this document and will deliberately change when the appliance moves to VLAN 60.

| Hostname (A record)          | IP Address     | VLAN | Device / Role                                   |
| ---                          | ---            | ---  | ---                                             |
| `udm.mgmt.matrix`            | `10.137.10.1`  | 10   | UDM Pro — gateway / firewall / UniFi controller |
| `catalyst.mgmt.matrix`       | `10.137.10.2`  | 10   | Cisco Catalyst 3850 management SVI              |
| `u7pro.mgmt.matrix`          | `10.137.10.7`  | 10   | UniFi U7 Pro WAP management                     |
| `morpheus.matrix`            | `10.137.20.2`  | 20   | Retired host retained as a cold spare           |
| `minis.matrix`               | `10.137.20.5`  | 20   | Homelab / Frigate NVR (server-side NIC)         |
| `ryze.matrix`                | `10.137.30.6`  | 30   | Desktop workstation                              |
| `bastion.matrix`             | `10.137.30.8`  | 30   | Dedicated OpenBSD VLAN 10 management bastion    |
| `slzb-mrw10u.iot.matrix`     | TBD            | 30 → 60 | SLZB-MRW10U Z-Wave/Zigbee coordinator; preserve this name and update its A record during migration |
| `worm.run`                   | `10.137.20.10` | 20   | minis cluster load balancer                     |
| `*.worm.run`                 | `10.137.20.10` | 20   | minis cluster load balancer                     |

> **NTP gap after Morpheus retirement.** The cameras still sync from `minis` at
> `192.168.105.1` using local `chrony` on the isolated camera-side NIC. VLAN 10 has no
> designated NTP source until a replacement is selected. `ntp.service.matrix`, the
> old DHCP option 42 advertisement, and the Morpheus UDP/123 exception must remain
> absent; do not repurpose the camera-only service implicitly.

**Deliberately excluded:**

* **`minis` camera-side NIC (`192.168.105.1`, VLAN 105)** — VLAN 105 never reaches the UDM and is off the trunk, so the UDM has no interface on `192.168.105.0/24` and cannot resolve or route it. Camera-side naming/DHCP is handled by `minis` `dnsmasq`, which is intentionally DHCP-only with no DNS.
* **`m5c` (`10.137.30.x`)** — DHCP-assigned with no static reservation, so its address is not stable enough for a fixed record.
* **`bastion` VLAN 10 (`10.137.10.8`)** — record it in inventory but do not
  publish it as an operator entry point. Operators resolve only
  `bastion.matrix` on VLAN 30.
* **WAN interfaces (AT&T / Spectrum)** — ISP-assigned, not internal hosts.

### Host Matrix

* **ryze (Desktop Workstation)**
  * *Connection:* Wired → UDM Port 1 (Native VLAN 30)
  * *IP / MAC:* `10.137.30.6` | `a8:a1:59:51:47:4e`
  * *Admin Access:* No direct routed access to VLAN 10 in steady state. Use SSH
    ProxyJump, local forwarding, or SOCKS through `bastion.matrix`; temporary
    direct access is allowed only during the documented Rule 940 break-glass
    window.


* **m5c (MacBook Laptop)**
  * *Connection:* WiFi → UniFi U7 Pro (VLAN 30 SSID)
  * *IP / MAC:* DHCP (`10.137.30.x`) | `aa:9a:b7:f2:ea:2d` (Turn off Private MAC address feature for reliable tracking).
  * *Admin Access:* Does not receive direct VLAN 10 administrative access in
    steady state. Use `bastion.matrix` for ProxyJump/local/SOCKS access;
    temporary direct access is allowed only during the documented Rule 940
    break-glass window. Direct VLAN 20 server administration remains allowed by
    the Trusted → Servers policy.


* **bastion (Wyse 5070 management bastion)**
  * *Connection:* Catalyst `Gi1/0/5` restricted trunk; native VLAN 99, tagged
    VLANs 10 and 30 only
  * *IP / MAC:* `10.137.10.8` (VLAN 10) and `10.137.30.8` (VLAN 30) | MAC TBD,
    recorded from `/var/db/bastion-wired-nic` after guarded preflight
  * *Role:* Sole VLAN 10 administrative entry path; no routing, bridging, NAT,
    remote subnet advertisement, application state, operator private key, or
    device credential. Unique host-local account passwords support console
    bootstrap and `doas` and are never reused elsewhere.


* **morpheus (Retired cold spare)**
  * *Role:* Powered-off cold spare since 2026-08-10; not required for normal network operation and no longer serving NTP, NFS, or other production workloads
  * *Connection:* Wired → UDM Port 2 (Native VLAN 20)
  * *IP / MAC:* `10.137.20.2` | `b4:2e:99:33:d6:0b`
  * *Reservation:* Keep `morpheus.matrix` and the UDM DHCP reservation for near-term recovery use. The cable remains connected while the host is powered off.


* **minis (Homelab + Frigate NVR)**
  * *Connection:* **Dual Physical NICs (No Bridging Allowed)**
  * *Server Link:* UDM Port 3 (Native VLAN 20) | `10.137.20.5` | `38:05:25:35:fb:d3` (NIC `lan0`)
  * *Camera Link:* Catalyst Port `Gi1/0/48` (Access VLAN 105) | Static `192.168.105.1` | `38:05:25:35:fb:d2` (NIC `cam0`)
  * *Link speed:* Both `minis` NICs are 2.5GbE, but the ports they connect to are only 1GbE — UDM Port 3 (`lan0` server-side) and Catalyst `Gi1/0/48` (`cam0` camera-side) — so both links negotiate at 1G.
  * *NFS:* No bulk filesystem is currently exported. A future service may export `/mnt/media` and `/mnt/games`; `/mnt/frigate` remains local-only and `/mnt/backups` stays unexported until a concrete consumer exists.

---

## 🛠️ Network Deployment Checklist

### Network Step 1: UniFi Dream Machine Configuration

* [X] Verify WAN failover prioritization: Primary = AT&T (Port 9), Failover = Spectrum (Port 8). This is **failover only** (not load-balancing); Spectrum sits idle until AT&T fails. Intentional for now — keeps a stable primary IP and avoids per-session path issues. Note: both WANs run on RJ45 ports (9 + 8), leaving the SFP+ WAN port (Port 10) free to be reassigned to LAN — this is confirmed working in the current setup. Since AT&T is 1G symmetric, the RJ45 WAN imposes no bottleneck.
* [X] Build out virtual networks/VLAN scopes (10, 20, 30, 60, 80). Set management IP gateway to `10.137.10.1`. Set each dynamic DHCP pool to `.100-.199` within its subnet. Also create **VLAN 99 as a "VLAN Only" network** (no gateway, no DHCP) so it can be selected as the native VLAN on the Port 10 trunk profile — UniFi requires the network to exist before it can be assigned as a native VLAN, so the blackhole trunk config below cannot be applied without it. Do **not** build VLAN 105 on the controller (it is an isolated, gateway-less segment that lives only on the Catalyst).
* [ ] Configure the UniFi U7 Pro management address as static-first at `10.137.10.7`, with a VLAN 10 UDM DHCP reservation for the same address as fallback.
* [X] Removed the VLAN 10 DHCP option 42 advertisement for `10.137.20.2`, `ntp.service.matrix`, and the obsolete VLAN 10 → Morpheus UDP/123 firewall exception. The host-level `morpheus.matrix` record and DHCP reservation remain for cold-spare recovery use. VLAN 10 has no designated NTP source until the deferred replacement is implemented.
* [X] Define the **DNS resolver strategy**: clients use the UDM per-VLAN gateway (`10.137.<vlan>.1`) as their resolver by default, and the UDM remains the long-term default resolver. VLAN 10 management devices and VLAN 20 hosts are static-first, but UDM DHCP reservations should map each known MAC to its intended address as fallback. Static addresses must be outside their dynamic DHCP pools. Set DNS manually on static hosts and point them at the UDM gateway unless a specific host has a deliberate exception. IoT (60) and Guest (80) are not forced through a specific upstream resolver, and external DNS/DoH is not blocked by design.
* [X] Commit custom port mapping profiles on UDM built-in interfaces (Port 1 → V30, Port 2 → V20, Port 3 → V20).
* [X] Configure UDM Port 10 as the Catalyst trunk profile: **Native/Untagged VLAN 99** (blackhole) to match the Catalyst's `switchport trunk native vlan 99`, plus tagged VLANs 10, 20, 30, 60, and 80. Both ends must agree on native VLAN 99 — a native-VLAN mismatch here would land untagged traffic in a live VLAN and defeat the blackhole design.
* [X] Configure UDM Port 11 as the WAP uplink profile: Native/Untagged VLAN 10 for AP management; Tagged VLANs 30, 60, and 80 for SSID client traffic.
* [ ] After the bastion tagged interfaces, PF, SSH listener, and Catalyst trunk
  pass their initial local checks, add `bastion.matrix` → `10.137.30.8` to UDM
  DNS before the VLAN 30 operator tests. Do not add an operator-facing record
  for `10.137.10.8`, and do not change Tailnet routes. This reversible DNS step
  does not authorize the Rule 940 firewall cutover.
* [X] **Verify VLAN tag-transparency through the unmanaged YuanLey switch:** connect a client to the Guest SSID and confirm it receives a `10.137.80.x` address (and an IoT-SSID client a `10.137.60.x` address) — *not* a `10.137.10.x` management address. A management-range lease means the YuanLey is stripping tags and the SSID separation has silently collapsed onto the management VLAN. If this fails, replace the YuanLey with a managed 2.5G PoE switch or temporarily move the AP to a Catalyst 1G port while preserving SSID VLAN separation.
* [ ] Migrate the SLZB-MRW10U from Trusted/VLAN 30 to IoT/VLAN 60: record its current IP and MAC, create a stable VLAN 60 UDM reservation, stage Rule 140 for TCP `6638`/`7638`, update `slzb-mrw10u.iot.matrix`, move the appliance, and rerun the Z-Wave JS UI, Zigbee2MQTT, and Zigbee2MQTT-monitoring validators. Preserve the fixed DNS name; do not enable mDNS reflection for this path.
* [ ] Deploy the numbered firewall rules from the Firewall & Traffic Flow Matrix in order: specific allows first, broad inter-VLAN drops second, WAN/internet egress policy separately. Enable Rule 940 as an unconditional Trusted/VLAN 30 → Admin/VLAN 10 drop only after the bastion passes its full validation. Preserve Rule 140 and other justified service-specific flows.
* [ ] Verify `ryze`, `m5c`, and another Trusted/VLAN 30 client cannot reach VLAN 10 directly but can reach `bastion.matrix:22` and use it for the documented ProxyJump, HTTPS local-forward, and SOCKS workflows.
* [ ] Verify a VLAN 10 client is not directed to `10.137.20.2` for NTP and cannot reach arbitrary VLAN 20 services or internet NTP servers. Record the lack of a designated VLAN 10 NTP source until the deferred replacement is implemented.

### Network Step 2: Cisco Catalyst 3850 Initialization

* [X] Set `vtp mode transparent` so the switch manages its own VLAN database locally and does not participate in VTP (matches the topology diagram).
* [X] Build out global VLAN tables database: `vlan 10,20,30,60,80,99,105`.
* [X] Set the management SVI default gateway: `ip default-gateway 10.137.10.1`. As a pure L2 switch (no `ip routing`), the VLAN 10 SVI (`10.137.10.2`) needs this for off-subnet reachability; routine operator SSH will originate from the directly connected bastion VLAN 10 address.
* [X] Provision SFP+ Uplink port `Te1/1/4` as a standard 802.1Q trunk. Force `switchport trunk native vlan 99` and set `switchport trunk allowed vlan 10,20,30,60,80,99` (VLAN 99 is included so the trunk carries its own native VLAN). Exclude VLAN 105 from the trunk.
* [ ] Confirm `Gi1/0/5` and both `.8` addresses are unused. Install and patch
  OpenBSD while `Gi1/0/5` remains access VLAN 30. The installer network must use
  static `10.137.30.8/24` with gateway/DNS `10.137.30.1`; the transfer path and
  staged SSH listener depend on that exact address. Then locally stage and parse
  the canonical VLAN/PF/SSH config. Convert the port to a trunk with native 99,
  allowed list exactly `10,30,99`, `switchport nonegotiate`, PortFast trunk, and
  BPDUguard. Follow `runbooks/bastion/README.md`; abort rather than choosing a
  different address or guessing the physical NIC.
* [X] Keep unused general-purpose wired ports `Gi1/0/6-36` as Access Mode on VLAN 30 for convenience. This is an intentional home-network tradeoff; unused ports are not disabled or parked in VLAN 99 by default. Reserve `Gi1/0/1-4` for VLAN 10 IPMI/IPKVM access devices, and do not treat those ports as general-purpose client access.
* [X] Configure `Gi1/0/1-4` as VLAN 10 access ports for IPMI/IPKVM devices.
* [X] Configure the camera deployment ports (`Gi1/0/37-47`) per the Local Camera Isolation config block: `switchport access vlan 105`, `switchport protected` (so cameras cannot talk to each other), `switchport block unicast`, `switchport block multicast`, plus `spanning-tree portfast` and `bpduguard enable`.
* [X] Configure the NVR camera-side ingestion port (`Gi1/0/48`) per the same block: `switchport access vlan 105` with `spanning-tree portfast` and `bpduguard enable`, but **without** `switchport protected` — this is intentional so the cameras on the protected ports can reach the `minis` NVR NIC.
* [X] Harden device management access: configure a privilege-15 local admin secret, enable `service password-encryption`, and disable plaintext remote access by allowing SSH only on the vty lines (`transport input ssh`). `enable secret` is intentionally skipped to avoid complicating the break-glass recovery procedure.

### Network Step 2.1: Bastion validation and firewall cutover

* [ ] Record the discovered Wyse Ethernet interface/MAC in the inventory and
  confirm the parent is unnumbered, only VLANs 10/30 exist, IPv6 is absent, the
  sole default route uses `10.137.30.1`, and both forwarding sysctls are zero.
* [ ] Confirm the Catalyst restricted trunk and the bastion's local PF/SSH
  checks pass. With the bastion DNS item in [Network Step 1](#network-step-1-unifi-dream-machine-configuration)
  complete, verify from VLAN 30 that `bastion.matrix` resolves to
  `10.137.30.8`, then perform the named operator workflows below before the
  Rule 940 firewall cutover.
* [ ] From VLAN 30, confirm only `10.137.30.8:22` accepts connections; approved
  keys work while root, password, and keyboard-interactive authentication fail.
  Confirm `10.137.10.8` has no listener and Admin devices cannot initiate a new
  session to the bastion. Inspect PF counters/pflog for expected drops.
* [ ] Validate ProxyJump to Catalyst SSH, HTTPS local forwarding, and SOCKS from
  both `ryze` and `m5c`. Confirm host DNS/NTP/patch access leaves VLAN 30 and a
  two-client test cannot route through the host.
* [ ] Repeat all tests after reboot and controlled AC loss. Only then remove
  the existing routed-management path by activating unconditional Rule 940. In
  a later break-glass event, disable Rule 940 through the VLAN 30 UDM UI when it
  is available and intentionally allow direct VLAN 30 to VLAN 10 management
  until recovery is complete. If the UDM is unavailable, Rule 940 may remain
  enabled while the Catalyst and Wyse are recovered from their physical
  consoles; that mode does not promise remote management access. Returning
  `Gi1/0/5` to access VLAN 30 supports a fresh install, but does not by itself
  restore network access to an already-hardened bastion because its PF policy
  permits host traffic only on tagged `vlan30`. The DNS record already exists
  for these tests and remains independent of the firewall cutover.

### Network Step 2.5: Camera Segment Services

* [X] Configure `minis` `dnsmasq` as the sole authoritative DHCP server on the camera-side NIC, with `dhcp-host` MAC-to-IP reservations for every known camera in `192.168.105.50-192.168.105.99` and the dynamic pool limited to `192.168.105.100-192.168.105.199` for unknown devices. Advertise `192.168.105.1` as the router for camera firmware compatibility, but keep nftables forwarding drops in place. Run DHCP-only (`port=0`)—do not serve DNS, which would be an outbound beacon path for a compromised camera. Verified during Phase 4 validation: the live config is authoritative and DHCP-only on `cam0`, and the sole deployed Amcrest camera receives reserved address `192.168.105.50`.
* [X] Configure the deployed camera for DHCP and local NTP at `192.168.105.1`. Do not configure a per-camera static IP; the `dnsmasq` reservation is the address source of truth.
* [X] Confirm `minis` is not bridging or NATing between its VLAN 20 server-side NIC and VLAN 105 camera-side NIC, and that nftables drops forwarded traffic entering or leaving `cam0`. Verified during Phase 4 validation with k3s running and `ip_forward=1`; the camera segment remains host-only.
* [X] Confirm cameras can reach `192.168.105.1` for Frigate/NVR ingestion and local NTP, but cannot reach VLAN 20, VLAN 30, VLAN 10, or the internet directly. Verified during Phase 4 validation; Frigate ingests the pinned camera while camera-segment forwarding remains blocked.

### Network Step 3: Network Cutover Runbook (From Legacy `172.17.1.0/24`)

* [X] Sweep all configuration files for hardcoded references to the legacy range (`/etc/hosts`, Nginx reverse-proxy configs, docker-compose files, `.env` blocks, and system mounts such as `/etc/fstab`).
* [X] Make the network changes during a dedicated maintenance window. Update DHCP reservations to the new `10.137.x.x` blocks.
* [X] Power-cycle connected devices and verify local services come back cleanly. In particular, confirm the legacy `172.17.1.0/24` range no longer collides with Docker's default `172.17.0.0/16` bridge network — this overlap is a primary motivation for the move to `10.137.x.x`.
