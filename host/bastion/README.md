# Bastion host configuration

Canonical, secret-free configuration for the bare-metal OpenBSD 7.9 management
bastion. Files under `etc/` mirror their installed paths except
`hostname.__WIRED_IF__`: the staging runbook discovers the Wyse's sole wired NIC,
renders that filename, and substitutes the same interface into both VLAN files.
It records the discovered interface and MAC in `/var/db/bastion-wired-nic`.
`pf.cutover.conf` is a temporary, interface-independent deny-all ruleset used
only while the tagged interfaces are being activated; `/etc/pf.conf` is the
persistent runtime policy. Activation stops the installer-era SSH listener
under deny-all, starts and verifies the hardened address-specific listener, and
only then loads the persistent policy that admits VLAN 30 TCP/22.

The host has no address on its physical parent. `vlan30` owns
`10.137.30.8/24`, the sole default route through `10.137.30.1`, DNS, NTP/update
egress, and the only SSH listener. `vlan10` owns `10.137.10.8/24` solely as a
source for operator-initiated management sessions. PF, SSH, and forwarding
settings prevent it from becoming a router or a listener on Admin/VLAN 10.
PF states are interface-bound so established traffic cannot match on the other
VLAN before its interface-specific rules are evaluated.
OpenNTPD queries only Cloudflare's documented IPv4 anycast NTP endpoints and
uses an independent HTTPS constraint; PF permits UDP/123 only to those two
addresses and permits TCP/443 for the `_ntp` user that retrieves the constraint.
Base-system web retrieval is limited to `_file` and `_syspatch`, allowing
`fw_update`, errata patching, and attended release upgrades without granting
general web egress to operators. `fw_update` downloads as `_file`, the
`file(1)` privsep account it reuses; this is not `_pkgfetch`, which this
package-free host never needs. OpenBSD's `sysupgrade` uses `_syspatch` for its
unprivileged network retrieval; there is no separate `_sysupgrade` account.
The parent explicitly clears `AUTOCONF4`; `dhcpleased`, `resolvd`, `rad`, and
`slaacd` are disabled; and cutover removes any installer lease/address/default
route before VLAN activation.

`home/charlie/.ssh/authorized_keys` contains the approved public key already
represented in the Catalyst source of truth. Public keys are not secrets. Add a
replacement or second approved key here before deployment if required; never put
operator private keys, reused passwords, device credentials, browser state, or
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
