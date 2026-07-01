# Apps

GitOps-managed workloads live here. The Phase 4 media, Frigate, and Home
Assistant manifests are implemented.

Current subdirectories:

- `media/` - Plex, download stack, Seerr, RomM
- `frigate/` - Frigate namespace, storage, service, ingress, deployment, config, and encrypted Secret placeholder
- `home-assistant/` - Home Assistant namespace, storage, service, ingress, and deployment

Do not add plaintext secrets. Commit app secrets only as SOPS-encrypted manifests.
