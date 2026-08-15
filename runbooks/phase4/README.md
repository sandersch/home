# Phase 4 - core workloads

Scripts for [build-plan.md Phase 4](../../docs/build-plan.md#phase-4--core-workloads-).

This directory starts with the Phase 4 media apps: the media download stack
(Gluetun, SABnzbd, qBittorrent, Prowlarr, Radarr, and Sonarr), Plex, Seerr, RomM,
Frigate, Home Assistant, and Zigbee2MQTT.

## Prerequisites

- The app-state gate has passed: either the original Phase 3.5 migration was
  validated, or the rebuild plan's full Restic `/opt` restore was validated while
  `apps` and the backup slice remained suspended.
- `/mnt/media` is mounted on `minis`.
- `/opt/plex/config` contains the selected migration/restore source, owned by UID/GID
  `1000:1000`.
- `/opt/radarr/config`, `/opt/sonarr/config`, and `/opt/prowlarr/config` contain the
  selected migration/restore source.
- `/mnt/games` is mounted on `minis` before reconciling RomM.
- `/mnt/frigate` is mounted on `minis` before reconciling Frigate.
- You have Mullvad WireGuard values from a device config.
- You have the Frigate RTSP username and password for the camera at `192.168.105.50`.
- On the original build, Home Assistant starts as a fresh install. On a rebuild,
  restore its state and managed backup artifacts with the rest of `/opt` before apps
  resume. Z-Wave JS UI connects to the network-attached SLZB-MRW10U; no USB stick is
  mounted on `minis`. Zigbee2MQTT uses the same appliance's separate TI Zigbee radio
  over `tcp://slzb-mrw10u.iot.matrix:7638`.

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

The deployed Frigate camera credentials are stored in the SOPS-encrypted Secret. For
a new installation or an intentional credential rotation, export the camera values
and run:

```bash
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER=...
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD=...
./runbooks/phase4/07-encrypt-frigate-secrets.sh
```

The script writes `apps/frigate/frigate.sops.yaml` with camera-specific RTSP credentials
and an auto-generated `FRIGATE_JWT_SECRET`; do not rerun it during ordinary operation
because doing so rotates that JWT secret. Do not commit a plaintext Secret. Future
cameras should use their own
`FRIGATE_CAMERA_<NAME>_RTSP_USER` and `FRIGATE_CAMERA_<NAME>_RTSP_PASSWORD` pair; the
script includes exported matching pairs automatically.

Frigate reads `/config/config.yml` from the generated `frigate-config` ConfigMap, with
`apps/frigate/config.yml` as the canonical source. Flux rolls the Deployment when that
file changes; the `frigate-config-pvc` still backs the rest of `/config` for Frigate
state.

Create the SOPS-encrypted Mosquitto Secret before reconciling MQTT and Frigate:

```bash
./runbooks/phase4/11-encrypt-mqtt-secrets.sh
```

The script writes `apps/mqtt/mosquitto-auth.sops.yaml` with separate Frigate and
Home Assistant accounts, plus `apps/frigate/frigate-mqtt.sops.yaml` with the
matching Frigate MQTT account. Decrypt the Mosquitto Secret locally with `sops` when
you need the Home Assistant MQTT credentials for the UI.

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
Gluetun Service URLs from the migration runbook. The legacy
`https://overseerr.worm.run` hostname is retained as a permanent redirect to the
canonical Seerr URL.

For RomM, validate the rollout, local state, database sidecar, service path, and
direct-attached library mount:

```bash
./runbooks/phase4/05-validate-romm.sh
```

Then open `https://romm.worm.run`, complete setup, and run the first library scan.

For Frigate, validate the rollout, PVCs, hardware passthrough, camera stream, and
camera-segment firewall posture:

```bash
./runbooks/phase4/09-validate-frigate.sh
```

Then open `https://frigate.worm.run` and confirm the `amcrest_105_50` camera is live.

For Home Assistant, validate the rollout, PVC, host networking, reverse-proxy seed
config, and in-cluster service path:

```bash
./runbooks/phase4/10-validate-home-assistant.sh
```

Then open `https://home-assistant.worm.run`, complete onboarding, and add LAN
integrations.

For Z-Wave JS, reconcile the new workload, validate the network-controller path, and
then complete the UI-managed Home Assistant integration:

```bash
./runbooks/phase4/13-validate-zwave-js.sh
```

The exact port-forward, security-key, WebSocket, and Home Assistant setup steps are
in `apps/home-assistant/README.md`.

For Zigbee2MQTT, first ensure the test ZHA integration has been deleted, reconcile
the app and broker credential update, and run:

```bash
./runbooks/phase4/14-validate-zigbee2mqtt.sh
```

Open `https://zigbee2mqtt.worm.run` and authenticate with the frontend token from the
SOPS-encrypted `apps/zigbee2mqtt/zigbee2mqtt-auth.sops.yaml` Secret. Enable joining
only while pairing. Home Assistant uses its existing MQTT integration to discover
paired devices automatically; do not add another Home Assistant integration.

For MQTT and the Frigate/Home Assistant connection, first confirm a current Home
Assistant backup and take the normal `/opt` btrfs snapshot. Then:

1. Decrypt `apps/mqtt/mosquitto-auth.sops.yaml` locally with `sops` and use the
   Home Assistant-specific account to add the MQTT integration. Values under Secret
   `data` remain base64-encoded after SOPS decryption, so decode each exactly once.
   Set the broker to `mosquitto.mqtt.svc.cluster.local:1883`, use TCP without TLS,
   and leave discovery enabled. Do not store the plaintext values in the repo.
2. Install HACS using its Home Assistant Container procedure, restart Home Assistant,
   and complete the HACS GitHub device authorization.
3. Install the Frigate integration from HACS, restart Home Assistant, and add Frigate
   with URL `https://frigate.worm.run` and the existing Frigate login.
4. Run the automated final-state validation:

```bash
./runbooks/phase4/12-validate-mqtt.sh
```

The validator creates and removes a short-lived MQTT client pod. It checks credential
parity without printing values, authenticated publish/subscribe, anonymous and bad
password rejection, retained Frigate availability, HA integration presence, and the
Frigate HTTPS path. Finally, listen to `frigate/#` in Home Assistant and trigger a
person event on `amcrest_105_50`; confirm a current `frigate/events` message and the
matching Home Assistant entity update.

Do not rerun `11-encrypt-mqtt-secrets.sh` during ordinary setup. If credentials are
intentionally rotated, reconcile the encrypted Secrets, restart Mosquitto and Frigate
in a controlled sequence, and update the Home Assistant broker login. Secret changes
alone do not roll either Deployment.

## Validation status

- Download stack: validated on 2026-07-18. The VPN egress and download/import
  workflow are operational.
- Plex: validated on 2026-07-18. The migrated server and library are intact, and
  Quick Sync transcoding is operational.
- Seerr: validated on 2026-07-18. The application, service path, Plex connection,
  and download-stack integration are operational.
- RomM: validated on 2026-07-18. The application, MariaDB sidecar, service path,
  local state, and direct-attached library are operational.
- Frigate: validated on 2026-06-30. `09-validate-frigate.sh` completed successfully,
  `amcrest_105_50` is live, Frigate logs show the Coral USB detector loaded (`TPU
  found`), `/api/stats` reports active Coral inference, and ffmpeg is using Intel QSV
  through `/dev/dri/renderD128`. `intel_gpu_top` on the host also confirmed
  hardware-accelerated ffmpeg activity.

- Home Assistant, MQTT, and the HACS Frigate integration: validated on 2026-07-18.
  Authenticated publish/subscribe, anonymous and bad-password rejection, retained
  Frigate availability, HA entity registration, HTTPS API reachability, and a real
  `amcrest_105_50` person event with matching occupancy changes all passed. HA's
  authenticated API-managed backup/restore path had already passed Phase 5 validation.
- Zigbee2MQTT: manifests and validation are present; live reconciliation, first
  coordinator start, and device discovery remain to be validated.

Remaining Phase 4 work is Frigate camera tuning (motion masks, zones, object filters,
and retention).
