# Cisco Catalyst 3850 — switch config

Source-of-truth config for the **Layer-2 distribution switch** (`catalyst`,
mgmt SVI `10.137.10.2`). This is network gear, not the `minis` host — see the
sibling [`host/minis/`](../minis/) for the server.

`running-config.ios` is the canonical IOS-XE config, written from
[docs/network.md](../../docs/network.md) (Network Step 2 + the Local Camera
Isolation block + the port-allocation table). It is a **template**, not a
byte-for-byte dump: secrets are redacted and a couple of lines marked `(exec)`
are run from privileged EXEC, not pasted into the config.

## Applying / restoring

Console in (or SSH once mgmt is up), enter `configure terminal`, and paste the
config. Then, from privileged EXEC:

1. **Set the redacted secrets** — replace `__REPLACE_WITH_ENABLE_SECRET__` and
   `__REPLACE_WITH_ADMIN_SECRET__` with the values from the password manager
   *before* pasting (or set them interactively: `enable secret …`,
   `username admin privilege 15 secret …`). They are stored as one-way hashes on
   the box; the cleartext is never committed here.
2. **Generate the SSH host key** (one-time, after `ip domain name matrix` is in
   place): `crypto key generate rsa modulus 2048`. SSH won't come up without it.
3. `write memory` to persist to `startup-config`.

Confirm before relying on it: `ryze` (VLAN 30) can SSH to `10.137.10.2`, the
`Te1/1/4` trunk is up to UDM Port 10, and VLAN 105 is **absent** from
`show interface trunk` (cameras must never reach the UDM).

## Invariants this config enforces

(From [docs/network.md → Canonical Invariants](../../docs/network.md); the
invariant wins if anything here ever conflicts.)

- **Strictly L2.** `ip routing` stays off. The VLAN 10 SVI is a management host
  IP only — the UDM Pro does all inter-VLAN routing.
- **VLAN 105 is never on the trunk.** The allowed list is `10,20,30,60,80,99`.
  Cameras are reachable only via the `minis` NVR NIC on `Gi1/0/48`.
- **VLAN 99 is the empty blackhole native VLAN.** Both trunk ends (here and UDM
  Port 10) must agree on native VLAN 99.
- **Camera ports are isolated from each other** (`switchport protected` +
  `block unicast`/`block multicast`); the NVR port `Gi1/0/48` deliberately omits
  all three so cameras can reach it.

## Keeping in sync

Hand-synced with the live switch — no automated apply. After changing the
running-config on the box, update this file (e.g. `show running-config`, then
re-redact the secret lines) so a future restore reflects reality.
