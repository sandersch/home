# ryze backup client

`usr/local/bin/vault-ingest` sends the encrypted Strongbox database every four hours
and supports an attended one-time `documents` seed. Its private Ed25519 key stays in
`~/.config/vault-ingest/`; only the public key is copied into the canonical `minis`
host configuration. Daily documents ingestion is intentionally deferred.

