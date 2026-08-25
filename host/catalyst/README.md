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

1. **Set the redacted admin secret** — replace
   `__REPLACE_WITH_ADMIN_SECRET__` with the value from the password manager
   *before* pasting (or set it interactively:
   `username admin privilege 15 secret …`). It is stored as a one-way hash on
   the box; the cleartext is never committed here. An `enable secret` is
   intentionally skipped to avoid complicating the break-glass recovery
   procedure; the privilege-15 local admin account is the remote admin path,
   and console access remains the recovery path.
2. **Generate the SSH host key** (one-time, after `ip domain name mgmt.matrix` is in
   place): `crypto key generate rsa modulus 2048`. SSH won't come up without it.
   The template also installs the `admin` user's SSH public key via
   `ip ssh pubkey-chain`, so key auth should work after the host key exists.
   That 2048-bit RSA key is **Catalyst-only**, forced by IOS-XE 16.12
   `ip ssh pubkey-chain` accepting no other algorithm. The bastion authorizes
   its own per-client Ed25519 keys and rejects this one; the two key sets are
   intentionally independent and must not be re-synced.
3. `write memory` to persist to `startup-config`.

Before the bastion cutover, leave Rule 940 inactive and confirm direct SSH from
`ryze` (`10.137.30.6`) to `10.137.10.2`, the `Te1/1/4` trunk is up to UDM Port
10, and VLAN 105 is **absent** from `show interface trunk` (cameras must never
reach the UDM). After the bastion is operational, confirm ProxyJump through
`bastion.matrix` can SSH to `10.137.10.2` before enabling Rule 940; that is the
steady-state management path, not an initial bring-up dependency.
Apply `ntp server 10.137.10.8` only after the bastion reports synchronized
upstream peers, a median HTTPS constraint, the exact VLAN 10-only listener, and
a successful VLAN 10 client query. Confirm `show ntp associations` and
`show ntp status` identify `.10.8` as the synchronization source. Save the
switch configuration only after the complete bastion reboot and controlled
AC-loss gate passes.

## Steady-state break-glass

The bastion is the routine management path, but recovery does not depend on it.
If it fails after Rule 940 has been enabled, use one of these recovery modes:

1. From VLAN 30, open the UDM UI directly at `https://10.137.30.1` and disable
   Rule 940 to restore the pre-cutover routed-management behavior. Confirm
   `ryze` can again SSH directly to the Catalyst at `10.137.10.2`, then change
   `Gi1/0/5` back to access VLAN 30 if the bastion requires a reinstall. Leave
   Rule 940 disabled until the rebuilt bastion passes its complete validation.
2. If UDM-mediated recovery is unavailable, use the Catalyst and bastion
   physical consoles. Rule 940 may remain enabled and remote management access
   is not expected. The Catalyst deliberately has no console login or enable
   secret, so privilege-15 recovery requires no network or stored credential.
   Enter `enable` if needed and verify `show privilege` before changing
   `Gi1/0/5` for a locally attended repair or reinstall.

Reassigning `10.137.30.8` to the physical parent of an already-hardened bastion
does not restore network access because its canonical PF policy permits traffic
only on tagged `vlan30`. Repair it locally or reinstall it on the temporary
access port; do not weaken PF for temporary remote access. The exact access-port
stanza, rebuild sequence, and validation gates are in
[`runbooks/bastion/README.md`](../../runbooks/bastion/README.md#steady-state-break-glass-after-firewall-cutover).

## Invariants this config enforces

(From [docs/network.md → Canonical Invariants](../../docs/network.md); the
invariant wins if anything here ever conflicts.)

- **Strictly L2.** `ip routing` stays off. The VLAN 10 SVI is a management host
  IP only — the UDM Pro does all inter-VLAN routing.
- **VLAN 105 is never on the uplink trunk.** The uplink allowed list is
  `10,20,30,60,80,99`. Cameras are reachable only via the `minis` NVR NIC on
  `Gi1/0/48`.
- **Gi1/0/5 is the bastion-only trunk.** Its native VLAN is 99 and its allowed
  list is exactly `10,30,99`; DTP is disabled. General VLAN 30 access ports begin
  at Gi1/0/6.
- **VLAN 99 is the empty blackhole native VLAN.** Both trunk ends (here and UDM
  Port 10) must agree on native VLAN 99.
- **Camera ports are isolated from each other** (`switchport protected` +
  `block unicast`/`block multicast`); the NVR port `Gi1/0/48` deliberately omits
  all three so cameras can reach it.

## Keeping in sync

Hand-synced with the live switch — no automated apply. After changing the
running-config on the box, update this file (e.g. `show running-config`, then
re-redact the secret lines) so a future restore reflects reality.
