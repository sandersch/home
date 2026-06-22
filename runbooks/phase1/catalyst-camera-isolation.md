# Catalyst Camera Isolation

Phase 1.1b is switch-side, not host-side. The host nftables rules only see traffic
that reaches `minis`; camera-to-camera traffic on the same Layer 2 segment must be
blocked on the Catalyst.

## Required State

- Camera ports `Gi1/0/37-47` are access ports in VLAN 105.
- Camera ports `Gi1/0/37-47` have:
  - `switchport protected`
  - `switchport block unicast`
  - `switchport block multicast`
  - PortFast and BPDU guard
- NVR ingestion port `Gi1/0/48` is access VLAN 105 and intentionally does not have
  `switchport protected`, `switchport block unicast`, or `switchport block multicast`.
- Uplink trunk `Te1/1/4` excludes VLAN 105.

## IOS Checks

Run from privileged EXEC on the Catalyst:

```text
show running-config interface range gi1/0/37 - 47
show running-config interface gi1/0/48
show interface trunk
show vlan id 105
```

Expected:

- `Gi1/0/37-47` show protected camera-port isolation.
- `Gi1/0/48` shows access VLAN 105 but no protected/block statements.
- `Te1/1/4` allowed VLANs are `10,20,30,60,80,99`; VLAN 105 is absent.
- VLAN 105 exists locally on the Catalyst.

## Traffic Validation

Use two temporary test clients on two protected camera ports, or two real cameras only
after their credentials are changed.

- Client A and Client B can each get DHCP from `minis` or can be manually assigned
  `192.168.105.x/24`.
- Client A can ping `192.168.105.1`.
- Client B can ping `192.168.105.1`.
- Client A cannot ping or connect to Client B.
- Client B cannot ping or connect to Client A.

Do not connect production cameras until this passes. Without this check, cameras may be
isolated from LAN and internet but still able to reach each other.
