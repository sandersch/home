# Apps

GitOps-managed workloads live here. The Phase 4 media, Frigate, Home Assistant, and
MQTT manifests are implemented.

Current subdirectories:

- `media/` - Plex, download stack, Seerr, RomM
- `frigate/` - Frigate namespace, storage, service, ingress, deployment, config, and SOPS-encrypted credentials
- `home-assistant/` - Home Assistant namespace, storage, service, ingress, and deployment
- `mqtt/` - Mosquitto namespace, storage, service, deployment, config, and SOPS-encrypted credentials

Do not add plaintext secrets. Commit app secrets only as SOPS-encrypted manifests.
