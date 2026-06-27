# Phase 4 - core workloads

Scripts for [build-plan.md Phase 4](../../docs/build-plan.md#phase-4--core-workloads-).

This directory starts with the first Phase 4 app: the media download stack
(Gluetun, SABnzbd, Prowlarr, Radarr, and Sonarr).

## Prerequisites

- Phase 3.5 validation has passed.
- `/mnt/media` is mounted on `minis`.
- `/opt/radarr/config`, `/opt/sonarr/config`, and `/opt/prowlarr/config` contain the
  migrated config from Phase 3.5.
- You have Mullvad WireGuard values from a device config.

## Secret generation

Create the SOPS-encrypted Gluetun Secret before reconciling `apps`:

```bash
export MULLVAD_WIREGUARD_PRIVATE_KEY=...
export MULLVAD_WIREGUARD_ADDRESSES=...
export MULLVAD_SERVER_COUNTRIES="United States"
./runbooks/phase4/01-encrypt-download-secrets.sh
```

`MULLVAD_SERVER_COUNTRIES` defaults to `United States` if unset.

The script writes `apps/media/download-stack/gluetun-mullvad.sops.yaml` and adds it
to the download-stack kustomization. Do not commit a plaintext Secret.

## Initial validation

The initial manifests mount `/mnt/media` read-only in SABnzbd, Radarr, and Sonarr.
Use that state to validate migrated config and VPN egress before allowing writes.

After Flux reconciles:

```bash
kubectl -n media rollout status deploy/gluetun
kubectl exec -n media deploy/gluetun -c sabnzbd -- sh -c 'wget -qO- ifconfig.me'
```

Only after the egress IP is a Mullvad exit IP should you configure indexers,
download clients, and a test download/import flow.
