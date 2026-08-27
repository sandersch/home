# Wyse 5070 OpenBSD management bastion

This is an attended, console-first deployment. The Wyse is a disposable
OpenBSD 7.9 endpoint with one physical 802.1Q trunk and two tagged interfaces;
it is not a router, bridge, NAT gateway, VPN endpoint, or Tailnet subnet router.
Operators enter through `bastion.matrix` on VLAN 30 and originate new sessions
to VLAN 10 from the host. OpenNTPD is the sole VLAN 10 inbound exception: it
serves only `10.137.10.9:123/udp`, while all upstream synchronization and the
HTTPS constraint leave through VLAN 30.

## 1. Pre-install gates

Before changing the machine or switch, verify all of the following and abort on
any ambiguity:

- From suitable existing hosts on VLANs 10 and 30, confirm `10.137.10.9` and
  `10.137.30.9` have no ping response, ARP/neighbor entry, UDM lease, reservation,
  or static assignment. A failed ping alone is not proof that an address is free.
  This is a one-time pre-install availability gate: after cutover PF deliberately
  blocks inbound ICMP, so ping is not a repeatable health check for the bastion.
- Confirm Catalyst `Gi1/0/5` is available, has no learned production MAC, and is
  still an access VLAN 30 port. Keep it that way through installation.
- Confirm the Wyse has exactly one enabled wired NIC, the OpenBSD 7.9 hardware
  support needed for its NIC/storage/console, a working local console, and each
  operator client's own approved Ed25519 private key. `ryze` holds
  `charlie@ryze` and `m5c` holds `charlessanders@air`; the bastion accepts only
  those two, listed in `host/bastion/home/charlie/.ssh/authorized_keys`. The
  separate RSA key in the Catalyst config is for `10.137.10.2` only and is not
  accepted here. Disable Wi-Fi/Bluetooth in BIOS even if OpenBSD would not
  attach it.
- Fetch the official OpenBSD 7.9 amd64 install image and `SHA256.sig` over HTTPS.
  Verify it with the release signing key documented by OpenBSD before writing
  installation media; do not treat HTTPS alone as signature verification. See
  the [OpenBSD 7.9 release page](https://www.openbsd.org/79.html).

Install OpenBSD 7.9 amd64 directly on the machine with the normal unencrypted
automatic disk layout. Select only the base/manual sets needed for a headless
system (no X sets), create `charlie`, and install no packages or compilers. Give
the installer-required `root` account and `charlie` unique, bastion-only local
passwords, save them in the password manager, and never reuse an operator or
device password. The host must retain no operator private key, device credential,
or browser profile. Set hostname `bastion`. While Catalyst `Gi1/0/5` remains an
access VLAN 30 port, configure the installer network statically and exactly as
`10.137.30.9/24`, with gateway and DNS both `10.137.30.1`. This address is
mandatory: the transfer command below and the staged SSH listener both depend on
it. If it is unavailable or does not work on the untagged access port, stop and
resolve that conflict rather than selecting a temporary substitute.

At the BIOS, set an administrator password and save it only in the password
manager. Select UEFI boot, enable automatic power-on after AC loss, disable
Wi-Fi/Bluetooth and unused boot devices, and require that password to re-enable
USB boot.

Patch before cutover:

```sh
syspatch
reboot
```

Perform attended OpenBSD release upgrades about every six months; follow the
release-specific `Upgrade Guide`, run `sysupgrade`, `sysmerge`, and `syspatch` as
directed, and repeat this complete validation afterward. Run `fw_update` after
installation and upgrades and when hardware firmware updates are required. PF
permits HTTP(S) for the base-system `_syspatch` and `_file` fetch users
specifically; `sysupgrade` performs its unprivileged retrieval as `_syspatch`,
and `fw_update` downloads as `_file`, the `file(1)` privsep account it reuses.
That is not `_pkgfetch`, which this package-free host never needs.
Do not relax PF or add general root/operator web egress for these workflows.
The base-system errata workflow is documented in
the [OpenBSD security updates FAQ](https://www.openbsd.org/faq/faq10.html).

## 2. Discover and stage

Do not clone or recursively copy the checkout onto the Wyse. The checkout can
contain the gitignored SOPS private key `age.key`, and OpenBSD base deliberately
has no Git client. From the repository root on an operator client, stream only
the two required directories over the mandatory installer address into a new,
private deployment tree:

```sh
shellcheck --severity=warning runbooks/bastion/*.sh
tar -cf - runbooks/bastion host/bastion | \
  ssh charlie@10.137.30.9 \
    'umask 077; test ! -e "$HOME/bastion-deploy" && mkdir "$HOME/bastion-deploy" && tar -xf - -C "$HOME/bastion-deploy"'
```

Shellcheck runs on the operator client; do not install a package on the
base-only bastion for this check. The transfer command refuses to merge into an
existing deployment tree. If SSH transfer
is unavailable during installation, create an archive containing exactly those
same two paths on trusted removable media; never archive or copy the checkout
root. Verify on the Wyse that `/home/charlie/bastion-deploy/age.key` does not
exist, then log in as `charlie` at its local console and enter a root login shell
for the first two privileged steps. A fresh OpenBSD installation has only the
example `/etc/examples/doas.conf`; membership in `wheel` does not authorize
`doas`, and the canonical `/etc/doas.conf` is not installed until the second
step succeeds. Do not create an ad hoc bootstrap policy or copy the example into
place.

Preflight independently refuses to continue if `age.key` is present at the
deployment root. The confirmation variable attests that the external gates
above were actually checked; the script cannot prove address or switch-port
availability from a single untagged link.

```sh
su -
cd /home/charlie/bastion-deploy
env BASTION_DEPLOYMENT_GATES_CONFIRMED=yes \
  runbooks/bastion/00-preflight.sh
runbooks/bastion/01-stage-config.sh
exit
```

`01-stage-config.sh` installs the canonical `/etc/doas.conf`. Only after that
script succeeds and the root shell exits should the remaining privileged
commands in this runbook be invoked through `doas` as `charlie`.

The preflight refuses any release other than OpenBSD 7.9, any installed X sets or
package, and anything other than one wired physical NIC. It records the detected
interface and MAC in `/var/db/bastion-wired-nic`; copy both into the inventory in
`docs/network.md`. To pin a MAC known from chassis records, additionally set
`BASTION_EXPECTED_MAC=aa:bb:cc:dd:ee:ff`.

Staging renders the actual interface name, checks `pfctl -nf`, `ntpd -n -f`,
`sshd -t`, the public-key file, and a `netstart -n` preview before transferring
the rendered files into `/etc`; it does not activate configuration.
`ntpd -n -f` parses both `query from` and `listen on`; in contrast,
`netstart -n` only prints the `ifconfig` operations it would run. It does not
exercise the split `parent`/`vnetid` declarations or the parent's
`inet -autoconf`/`-inet` commands against the kernel. Keep the local console
open. Re-run staging safely if needed.

Do not reboot after staging until `Gi1/0/5` has been converted to the canonical
restricted trunk and activation and local validation have passed. A reboot in
that interval applies the tagged interface files and VLAN 30-only SSH listener
while the switch port is still untagged access VLAN 30, so remote access is
expected to be unavailable. If an unplanned reboot occurs, keep Rule 940
disabled and recover from the Wyse console: restore or establish Catalyst
management access, complete the restricted-trunk cutover, and rerun activation
and local validation. Use the deployment rollback section below if the trunk
cannot be completed safely.

The local validator later confirms all four network autoconfiguration daemons
are disabled and stopped, the installed resolver, PF, and OpenNTPD policies
exactly match their canonical source files, and both VLAN interfaces have the
recorded physical parent and exact expected vnetid.

## 3. Catalyst trunk cutover

At the Catalyst console/SSH session, re-check `show interfaces Gi1/0/5 status`,
`show mac address-table interface Gi1/0/5`, and the saved rollback commands.
Close every remote session to the Wyse before continuing; activation is
console-only and deliberately flushes all PF state after loading deny-all. Keep
the Catalyst management session open because it terminates on the switch, not
the Wyse.
Apply the canonical stanza from `host/catalyst/running-config.ios`:

```ios
configure terminal
interface GigabitEthernet1/0/5
 description bastion restricted trunk (OpenBSD)
 switchport mode trunk
 switchport trunk native vlan 99
 switchport trunk allowed vlan 10,30,99
 switchport nonegotiate
 spanning-tree portfast trunk
 spanning-tree bpduguard enable
end
```

From the physical Wyse console, activate the already-staged configuration:

```sh
cd /home/charlie/bastion-deploy
doas env BASTION_LOCAL_CONSOLE=yes runbooks/bastion/02-activate.sh
doas runbooks/bastion/03-validate.sh
```

Activation is the first real execution of the rendered parent and VLAN
`ifconfig` commands. It runs with `set -e`, and its explicit parent-address and
`AUTOCONF4` assertions abort locally on failure. Before changing runtime state,
it also refuses an installed `/etc/rc.conf.local` that differs from the staged
canonical file. Its `rcctl` actions start or stop daemons only; they do not
rewrite that file. Do not leave the console or
begin remote operator tests unless the immediately following
`03-validate.sh` run confirms both VLAN addresses, exact parent/vnetid bindings,
the default route, resolver policy, daemon state, PF/SSH invariants, and bounded
OpenNTPD health gate.

If activation stops after changing runtime state, keep the local console open
and Rule 940 disabled, correct the reported cause, and rerun `02-activate.sh`;
the script reapplies deny-all before rebuilding the intended runtime state.
Rerun `01-stage-config.sh` only when activation explicitly reports canonical
installed-file or daemon-policy drift. Staging alone does not repair partially
activated runtime state.

Activation first forces both forwarding sysctls to zero and loads/enables an
interface-independent deny-all PF cutover policy. It then flushes the complete
PF state table and refuses to continue unless that table is empty and no
installer-era SSH session remains established, so an SSH or other pre-hardening
connection cannot survive the ruleset and interface transition. It then stops
the installer-era SSH listener while deny-all is still active. This one-time
session assertion belongs to the console-only activation script;
`03-validate.sh` may be rerun later from either the physical console or an SSH
session without rejecting the session that invoked it. Activation next creates
only unattached VLAN devices needed to parse the final policy. Only after those
operations succeed does it confirm `dhcpleased`, `resolvd`, `rad`, and `slaacd`
are configured disabled, stop any that remain running, clear the parent's
`AUTOCONF4` flag, remove all installer IPv4 addresses/default routes, verify
that cleanup, and attach/configure the tagged interfaces.
`/etc/sysctl.conf` remains the boot-time source of truth; cutover sets
the two values directly so a parser or unrelated sysctl entry cannot leave the
host exposed midway through activation. After address assignment and the final
default route are in place, activation starts SSH from the staged hardened
configuration, restarts OpenNTPD, and locally verifies the exact listeners:
`10.137.30.9:22/tcp` and `10.137.10.9:123/udp`. It rejects an NTP listener on
`10.137.30.9` or a wildcard address. The final PF policy replaces deny-all only
after those checks, so a failure cannot expose the installer-era authentication
policy and `antispoof` expands against the connected networks. Because that
first OpenNTPD start occurred under deny-all only to prove its listener,
activation restarts it once more after the final policy is active and verifies
the listener again. This discards blocked bootstrap attempts and lets the peers
and HTTPS constraint start with their exact egress policy available.
That policy binds every state to the interface where it was created; the local
validator confirms the active pass rules carry `if-bound` state semantics.
The staged `/etc/ntpd.conf` fixes OpenNTPD to Cloudflare's two documented IPv4
anycast endpoints, sources queries from `10.137.30.9`, listens only on
`10.137.10.9`, and retains an independent HTTPS time constraint. PF permits
inbound UDP/123 only from VLAN 10 to that address, outbound UDP/123 only to the
two pinned endpoints, and TCP/443 only for the `_ntp` process that retrieves the
constraint.

The local validator fails structural host, listener, configuration, and PF
invariants immediately. Only live OpenNTPD health is allowed to converge: it
waits up to 180 seconds for both pinned peers to become valid, the clock to
synchronize, and a median HTTPS constraint to appear. If that bound expires, it
prints the last `ntpctl -s all` status and reports a specific NTP health failure;
leave Rule 940 disabled and diagnose upstream reachability from the console.

Confirm the switch independently:

```ios
show interfaces Gi1/0/5 switchport
show interfaces trunk
show spanning-tree interface Gi1/0/5 detail
```

The operational mode must be trunk, native VLAN 99, and allowed list exactly
`10,30,99`. VLANs 20, 60, 80, and 105 must be absent.

## 4. Operator and isolation tests

After the local validator and Catalyst restricted-trunk checks pass, add only
`bastion.matrix -> 10.137.30.9` to UDM DNS. Do not yet add
`ntp.service.mgmt.matrix`, advertise DHCP option 42, publish an operator-facing
record for `10.137.10.9`, or change Tailnet routes. From both `ryze` and `m5c`,
confirm `bastion.matrix` resolves to `10.137.30.9`, login with that client's own
Ed25519 key succeeds, and root/password/keyboard-interactive login fails. Both
clients must be tested: each authorizes a different key, so a success from one
proves nothing about the other. Confirm the Catalyst RSA key is rejected by the
bastion (`ssh -o IdentitiesOnly=yes -i <rsa-key> charlie@bastion.matrix` must
fail) while ProxyJump to `10.137.10.2` with it still succeeds. Scan or probe `10.137.30.9` and
confirm TCP/22 is the only listener. Also confirm NTP does not answer on either
bastion address from VLAN 30.

Before publishing the time service, use `ntpctl -s all` and `tcpdump` on the
bastion to confirm both pinned peers are healthy, the clock is synchronized, a
median HTTPS constraint is present, and every upstream UDP/123 packet sources
from `10.137.30.9` toward only `162.159.200.1` or `162.159.200.123`. Confirm no
upstream NTP leaves `vlan10`.

Only after that health gate passes, add
`ntp.service.mgmt.matrix -> 10.137.10.9` to UDM DNS and advertise exactly one
DHCP option 42 address on VLAN 10: `10.137.10.9`. Confirm the retired
`ntp.service.matrix`, `10.137.20.2` option 42 value, and Morpheus UDP/123
exception are absent. Renew a VLAN 10 test lease, resolve the new name through
the UDM, and inspect the lease to prove option 42 contains `.10.9` and never
`.20.2`.

From an Admin/VLAN 10 test host, confirm a query to `10.137.10.9` succeeds and
its reply comes from that address; a combined TCP/UDP scan finds only UDP/123 on
`.10.9`, ICMP remains denied, and no other new connection to either bastion
address succeeds. From every other reachable VLAN, confirm neither bastion
address answers NTP.

Representative workflows:

```sh
# Catalyst SSH through the bastion
ssh -J charlie@bastion.matrix admin@10.137.10.2

# Local HTTPS forward; browse locally to https://127.0.0.1:8443
ssh -N -L 8443:10.137.10.1:443 charlie@bastion.matrix

# Local SOCKS proxy for VLAN 10 targets only
ssh -N -D 1080 charlie@bastion.matrix

# Patch the bastion itself; DNS/NTP/update egress must use VLAN 30
ssh charlie@bastion.matrix
doas syspatch
doas fw_update
```

Use `route -n show -inet`, `ifconfig`, `netstat -an`, `pfctl -sr -v`,
`pfctl -ss`, `ntpctl -s all`, and `tcpdump -n -e -ttt -i pflog0` to verify the
sole default route, listener, states/counters, NTP peers, active HTTPS constraint,
and expected VLAN 10 drops. Do not accept NTP validation until `ntpctl -s all`
shows synchronized peers and a median constraint. Test ProxyJump, the local
forward, and SOCKS against representative SSH/HTTPS endpoints in
`10.137.10.0/24`; forwarded connections outside that subnet are expected to
fail. A two-client test must show that traffic
cannot traverse the host between VLANs even when a client tries to use it as a
gateway.

Test the denial log limiter from an Admin/VLAN 10 test host as an attended gate.
Record both `pfctl -s labels | grep vlan10-denied` counters on the bastion, send a
controlled burst above five packets per second to `10.137.10.9` (for example,
50 ICMP requests at 50 ms intervals), and read both counters again immediately.
The logged and unlogged counters must both increase, while `pflog0` must contain
only the packets counted by `vlan10-denied-logged`. Label presence alone does not
validate the rate transition.

Only after local NTP synchronization, listener, and VLAN 10 client tests pass,
apply `ntp server 10.137.10.9` from the canonical Catalyst configuration. Verify
the switch reports synchronization with `.10.9`, but do not write memory yet.
Configure each other known static VLAN 10 device to use `10.137.10.9` where its
platform supports an explicit NTP server, and record its exposed time status.
If the UDM Pro, U7 Pro, or an IPMI/IPKVM platform does not support a custom NTP
server, document that limitation; do not grant internet NTP, add routing, or
replace static-first addressing to work around it.

Reboot and rerun `doas runbooks/bastion/03-validate.sh`, either at the physical
console or over SSH, then repeat the client validation. Perform a controlled AC
loss and repeat that same host and client validation, confirming automatic
power-on, normal boot, tagged interfaces, PF, sshd, DNS/NTP/update egress, and
all three operator workflows. Renew the VLAN 10 test lease again, repeat the
NTP queries and isolation scans, and reconfirm the Catalyst and supported static
clients after both reboot and AC loss.

Only after those gates pass should the UDM firewall change be made: enable Rule 940 as an
unconditional VLAN 30 to VLAN 10 drop. Verify `ryze`, `m5c`, and another VLAN 30
client cannot reach VLAN 10 directly while all can still reach
`bastion.matrix:22`. Rule 140 and other service-specific flows remain.
Save the UDM and Catalyst configurations only after this complete gate passes.

## 5. Remove deployment files

After the reboot, AC-loss, and final UDM firewall tests all pass, remove the
temporary deployment tree from the Wyse. Run this exact command as `charlie`,
not through `doas`; it removes only the two-directory transfer above and does
not affect the installed configuration under `/etc`:

```sh
rm -rf /home/charlie/bastion-deploy
test ! -e /home/charlie/bastion-deploy
```

Do not remove it earlier: the validation script and rollback procedure remain
available from this tree until the complete deployment gate has passed.

## Steady-state break-glass after firewall cutover

After Rule 940 has been enabled, recovery must not depend on the failed bastion.
Two recovery modes remain:

1. **UDM available:** from a healthy VLAN 30 client, open the UDM UI directly at
   `https://10.137.30.1` and disable Rule 940. Confirm direct VLAN 30 to VLAN 10
   management access is restored and `ryze` can again SSH to the Catalyst at
   `10.137.10.2`. Direct VLAN 10 access is intentional for the duration of this
   break-glass window. Leave Rule 940 disabled throughout diagnosis or rebuild
   and re-enable it only after the bastion again passes its complete validation.
2. **UDM unavailable:** use the Catalyst and bastion physical consoles. Rule 940
   may remain enabled; this recovery mode does not promise remote management
   access. The Catalyst deliberately has no console login or enable secret, so
   enter `enable` if its prompt is `>` and confirm `show privilege`. Diagnose
   the Wyse locally. If a rebuild is required, return `Gi1/0/5` to the access
   VLAN 30 stanza below, reinstall OpenBSD using the documented installer
   address, transfer and stage the canonical configuration, and repeat the
   attended trunk cutover. Physical custody of both hosts is therefore part of
   this break-glass boundary.

Keep the chosen UDM or Catalyst recovery session open while reinstalling and
restaging the Wyse. Do not restore the trunk until the rebuilt bastion has
passed its local checks and is ready for the attended trunk cutover. Then repeat
the complete operator, reboot, AC-loss, and Rule 940 validation before returning
to steady state. In the console-only mode, Rule 940 remains unchanged until the
UDM becomes available; its enabled state does not prevent the rebuilt bastion
from using its directly connected VLAN 10 interface after trunk activation.

## Deployment rollback and local console recovery

During initial deployment, leave Rule 940 disabled until every validation gate
passes. If a later failure occurs after Rule 940 has been enabled, use the
applicable steady-state recovery mode above rather than assuming the bastion can
restore its own access. Return the Catalyst port to its temporary access
configuration when local repair or a reinstall requires the untagged installer
network:

For an NTP-only rollback, first remove DHCP option 42 and
`ntp.service.mgmt.matrix`, then return supported static clients to an
unconfigured NTP state. Remove `ntp server 10.137.10.9` from the Catalyst before
removing the bastion listener and PF exception. Never restore
`ntp.service.matrix`, the `10.137.20.2` advertisement, or the retired Morpheus
UDP/123 exception.

```ios
configure terminal
default interface GigabitEthernet1/0/5
interface GigabitEthernet1/0/5
 description General wired clients (VLAN 30) - bastion rollback
 switchport mode access
 switchport access vlan 30
 spanning-tree portfast
 spanning-tree bpduguard enable
end
```

An already-hardened installation does not regain network access merely by moving
`10.137.30.9` to the physical parent: the canonical PF policy permits host
traffic only on tagged `vlan30`. Diagnose and repair that installation from the
Wyse local console, then restore the trunk and rerun activation. Do not weaken
PF/sshd or enable routing to obtain temporary remote access. If the system cannot
boot or cannot be repaired locally, reinstall it while `Gi1/0/5` is access VLAN
30; the fresh installer may use static `10.137.30.9/24` with gateway/DNS
`10.137.30.1` for patching and transfer before the canonical tagged configuration
is staged. There is no application state to restore. Save the validated switch
and UDM configuration only after the complete reboot and AC-loss gate passes.

## Proxmox alternative (deferred)

If virtualization is reconsidered, terminate VLANs on a VLAN-aware Proxmox bridge
and give the guest two hypervisor-tagged vNICs that appear untagged inside the VM.
Do not pass the physical trunk into the guest; keeping access-VLAN policy in the
hypervisor makes the guest configuration and isolation boundary explicit. See
the [Proxmox network configuration reference](https://pve.proxmox.com/wiki/Network_Configuration).
