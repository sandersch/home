# Phase 3 encrypted secrets

Run `runbooks/phase3/01-encrypt-secrets.sh` on `minis` with the real CloudDNS
service-account JSON and Tailscale OAuth credentials. The script writes the
SOPS-encrypted CloudDNS Secret into this directory and the SOPS-encrypted Tailscale
OAuth Secret into `infrastructure/controllers/tailscale/`, where it reconciles before
the operator HelmRelease.
