# Phase 3 encrypted secrets

Run `runbooks/phase3/01-encrypt-secrets.sh` on `minis` with the real CloudDNS
service-account JSON and Tailscale OAuth credentials. The script writes only
SOPS-encrypted Secret manifests into this directory.
