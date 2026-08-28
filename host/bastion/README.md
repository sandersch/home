# Bastion host configuration

Canonical, secret-free configuration for the bare-metal OpenBSD 7.9 management
bastion. Files under `etc/` mirror their installed paths except
`hostname.__WIRED_IF__`: the staging runbook discovers the Wyse's sole wired NIC,
renders that filename, and substitutes the same interface into both VLAN files.
It records the discovered interface and MAC in `/var/db/bastion-wired-nic`.
`pf.cutover.conf` is a temporary, interface-independent deny-all ruleset used
only while the tagged interfaces are being activated; `/etc/pf.conf` is the
persistent runtime policy. Activation stops the installer-era SSH listener
under deny-all, starts and verifies the two hardened address-specific listeners,
and only then loads the persistent policy that admits VLAN 30 TCP/22 and VLAN 10
UDP/123.

The host has no address on its physical parent. `vlan30` owns
`10.137.30.9/24`, the sole default route through `10.137.30.1`, DNS, NTP/update
egress, and the only SSH listener. `vlan10` owns `10.137.10.9/24` as a source
for operator-initiated management sessions and the only OpenNTPD listener. PF,
SSH, and forwarding settings prevent it from becoming a router or exposing any
other service on Admin/VLAN 10.
PF states are interface-bound so established traffic cannot match on the other
VLAN before its interface-specific rules are evaluated.
OpenNTPD queries only Cloudflare's documented IPv4 anycast NTP endpoints and
uses an independent HTTPS constraint. It listens only on `10.137.10.9`; PF
permits inbound UDP/123 only from `10.137.10.0/24`, outbound UDP/123 only to the
two pinned addresses through VLAN 30, and TCP/443 for the `_ntp` user that
retrieves the constraint.
Base-system web retrieval is limited to `_file` and `_syspatch`, allowing
`fw_update`, errata patching, and attended release upgrades without granting
general web egress to operators. `fw_update` downloads as `_file`, the
`file(1)` privsep account it reuses; this is not `_pkgfetch`, which this
package-free host never needs. OpenBSD's `sysupgrade` uses `_syspatch` for its
unprivileged network retrieval; there is no separate `_sysupgrade` account.
The parent explicitly clears `AUTOCONF4`; `dhcpleased`, `resolvd`, `rad`, and
`slaacd` are disabled; and cutover removes any installer lease/address/default
route before VLAN activation.

`home/charlie/.ssh/authorized_keys` contains one Ed25519 public key per approved
operator client:

| Comment | Client | Fingerprint |
| --- | --- | --- |
| `charlie@ryze` | `ryze` desktop (`10.137.30.6`) | `SHA256:g0Wr0NZ2IL+h+cB22FgHZ4oso5N2iaehlHzi20A9y6M` |
| `charlessanders@air` | `m5c` MacBook | `SHA256:ghRp75W5/5X00LYFMh8ZVui3IlxOZlH5z1gEp2Nv8pw` |

These are deliberately **not** the 2048-bit RSA key in
`host/catalyst/running-config.ios`. IOS-XE 16.12 `ip ssh pubkey-chain` accepts
only RSA, so the Catalyst keeps its own key while the bastion uses modern
per-client keys. Nothing is lost by the split: `sshd_config` sets
`AllowAgentForwarding no`, and ProxyJump authenticates each hop from the
operator client, so the Catalyst RSA private key never reaches this host.
Revoking one client is a one-line change here; revoking Catalyst access is a
separate change on the switch.

Public keys are not secrets. Add or remove approved keys here before deployment
as required, one per client so revocation stays per-client; never put operator
private keys, reused passwords, device credentials, browser state, or
application secrets on this disposable machine. The unique local `root` and
`charlie` passwords required for console bootstrap and `doas` are retained only
as host-local password hashes and in the external password manager.

Use [`runbooks/bastion/README.md`](../../runbooks/bastion/README.md) for the
attended install, trunk cutover, validation, and rollback procedure. Transfer
only `runbooks/bastion/` and `host/bastion/` in their repository-relative
layout—never copy the checkout root, which may contain the gitignored SOPS
private key `age.key`. Do not install configuration files by hand: the guarded
stage script validates daemon policy and previews interface commands, but
`netstart -n` does not exercise those commands against the kernel. Activation
and the immediately following local validator are the required first runtime
test. Remove the temporary two-directory deployment tree after the complete
reboot, AC-loss, and firewall gate passes.
