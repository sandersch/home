# Phase 4 - core workloads

Scripts for [build-plan.md Phase 4](../../docs/build-plan.md#phase-4--core-workloads-).

This directory starts with the Phase 4 media apps: the media download stack
(Gluetun, SABnzbd, qBittorrent, Prowlarr, Radarr, and Sonarr), Plex, Seerr, RomM,
and Frigate.

## Prerequisites

- Phase 3.5 validation has passed.
- `/mnt/media` is mounted on `minis`.
- `/opt/plex/config` contains the migrated Plex config from Phase 3.5, owned by
  UID/GID `1000:1000`.
- `/opt/radarr/config`, `/opt/sonarr/config`, and `/opt/prowlarr/config` contain the
  migrated config from Phase 3.5.
- `/mnt/games` is mounted on `minis` before reconciling RomM.
- `/mnt/frigate` is mounted on `minis` before reconciling Frigate.
- You have Mullvad WireGuard values from a device config.
- You have the Frigate RTSP username and password for the camera at `192.168.105.50`.

## Secret generation

Create the SOPS-encrypted Gluetun Secret before reconciling `apps`:

```bash
export MULLVAD_WIREGUARD_PRIVATE_KEY=...
export MULLVAD_WIREGUARD_ADDRESSES=...
./runbooks/phase4/01-encrypt-download-secrets.sh
```

The script writes `apps/media/download-stack/gluetun-mullvad.sops.yaml` with only
the WireGuard values and adds it to the download-stack kustomization. Non-secret
Gluetun settings such as provider, server country, firewall ports, and local subnets
live in `apps/media/download-stack/configmap.yaml`. Do not commit a plaintext Secret.

To add optional RomM metadata-provider credentials, export one or more supported
variables and run:

```bash
export IGDB_CLIENT_ID=...
export IGDB_CLIENT_SECRET=...
./runbooks/phase4/06-add-romm-provider-secrets.sh
```

The script also accepts `SCREENSCRAPER_USER`, `SCREENSCRAPER_PASSWORD`,
`RETROACHIEVEMENTS_API_KEY`, and `STEAMGRIDDB_API_KEY`. It preserves existing RomM
DB/auth keys by decrypting the current SOPS file locally, so the matching age identity
must be available in the shell.

Create the SOPS-encrypted Frigate Secret before reconciling Frigate:

```bash
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER=...
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD=...
./runbooks/phase4/07-encrypt-frigate-secrets.sh
```

The script writes `apps/frigate/frigate.sops.yaml` with camera-specific RTSP credentials
and an auto-generated `FRIGATE_JWT_SECRET`. The committed encrypted file is only a
placeholder until this script is rerun with the real camera credentials. Do not commit a
plaintext Secret. Future cameras should use their own
`FRIGATE_CAMERA_<NAME>_RTSP_USER` and `FRIGATE_CAMERA_<NAME>_RTSP_PASSWORD` pair; the
script includes exported matching pairs automatically.

## Initial validation

After Flux reconciles:

```bash
./runbooks/phase4/02-validate-download-stack.sh
```

Only after the egress IP is a Mullvad exit IP should you configure indexers,
download clients, and test download/import flows. Open `https://qbittorrent.worm.run`,
complete the initial Web UI credential setup, then set qBittorrent's incomplete path
to `/incomplete` and completed path to `/media/downloads/torrents`. Add it to
Radarr/Sonarr as `localhost:8090` with app-specific categories, keeping SABnzbd on
`localhost:8080`.

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

For RomM, validate the rollout, local state, database sidecar, service path, and
NAS-backed library mount:

```bash
./runbooks/phase4/05-validate-romm.sh
```

Then open `https://romm.worm.run`, complete setup, and run the first library scan.

For Frigate, validate the rollout, PVCs, hardware passthrough, camera stream, and
camera-segment firewall posture:

```bash
kubectl -n frigate rollout status deploy/frigate
kubectl -n frigate get pvc
kubectl -n frigate exec deploy/frigate -- ls -la /dev/bus/usb /dev/dri/renderD128
kubectl -n frigate logs deploy/frigate
```

Then open `https://frigate.worm.run` and confirm the `amcrest_105_50` camera is live.
