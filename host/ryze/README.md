# ryze backup client

`usr/local/bin/vault-ingest` sends the encrypted Strongbox database every four hours
and uses the shared portable document uploader. Its private Ed25519 key stays in
`~/.config/vault-ingest/`; only the public key is copied into the canonical `minis`
host configuration. The staged workstation daily due-check independently retries
NAS backup and document uploads hourly. Its timer is not yet installed/enabled.
See [the attended workstation runbook](../../runbooks/backups/workstations.md).

Approved recovery limitation (released in contract v3 on 2026-10-30): self-managed
downloads are excluded. On 2026-10-29 Codex removed 9.67 GB of old releases from
`.codex/packages`, dropping the home scope below the 80% shrink threshold; an attended
audit then found 16.89 GB and 437,204 files of the 26.20 GB scope in subtrees that their
own tools rotate or rebuild. v3 omits Codex and Claude Code release binaries, Discord app
builds and update staging, Chrome Service Worker caches and downloaded components, NVIDIA
shader caches, `.rbenv/versions`, `.nvm/versions`, `go/pkg/mod`, `.yarn/berry/cache`,
`.magefile`, Lutris runners and runtime, and old Paradox launcher builds. Ruby, Node and
Go toolchains, agent CLIs and Lutris runners must be reinstalled after a restore; game
saves, wine prefixes and Lutris's game database remain in scope.
