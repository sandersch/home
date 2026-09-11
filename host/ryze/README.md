# ryze backup client

`usr/local/bin/vault-ingest` sends the encrypted Strongbox database every four hours
and uses the shared portable document uploader. Its private Ed25519 key stays in
`~/.config/vault-ingest/`; only the public key is copied into the canonical `minis`
host configuration. The staged workstation daily due-check independently retries
NAS backup and document uploads hourly. Its timer is not yet installed/enabled.
See [the attended workstation runbook](../../runbooks/backups/workstations.md).
