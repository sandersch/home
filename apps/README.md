# Apps

GitOps-managed workloads live here. The Phase 4 media and Frigate manifests are
mostly implemented; Home Assistant is still a placeholder.

Current subdirectories:

- `media/` - Plex, download stack, Seerr, RomM
- `frigate/` - Frigate namespace, storage, service, ingress, deployment, config, and encrypted Secret placeholder
- `home-assistant/` - placeholder for Home Assistant and related device integrations

Do not add plaintext secrets. Commit app secrets only as SOPS-encrypted manifests.
