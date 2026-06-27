# Phase 4 - core workloads

Scripts for [build-plan.md Phase 4](../../docs/build-plan.md#phase-4--core-workloads-).

This directory starts with the first Phase 4 apps: the media download stack
(Gluetun, SABnzbd, Prowlarr, Radarr, and Sonarr) and Plex.

## Prerequisites

- Phase 3.5 validation has passed.
- `/mnt/media` is mounted on `minis`.
- `/opt/plex/config` contains the migrated Plex config from Phase 3.5, owned by
  UID/GID `1000:1000`.
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

For Plex, validate the rollout and device passthrough:

```bash
./runbooks/phase4/03-validate-plex.sh
```

After first boot, confirm the migrated server appears without `PLEX_CLAIM`, set the
custom server access URL to `https://plex.worm.run`, keep Plex native Remote Access
disabled, and force a 1080p transcode while watching hardware use with `intel_gpu_top`
on the host.

For Seerr, validate the rollout and in-cluster service path:

```bash
./runbooks/phase4/04-validate-seerr.sh
```

Then open `https://seerr.worm.run`, link Plex, and point Radarr/Sonarr at the
Gluetun Service URLs from the migration runbook.
