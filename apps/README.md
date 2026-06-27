# Apps

GitOps-managed workloads live here after the cluster platform is ready.

Expected subdirectories:

- `media/` - Plex, download stack, Seerr, RomM
- `frigate/` - Frigate and camera-related workload manifests
- `home-assistant/` - Home Assistant and related device integrations

Do not add plaintext secrets. Commit app secrets only as SOPS-encrypted manifests.
