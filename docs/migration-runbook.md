# Migration Runbook — Plex & *arr

Moving existing application state from the current ArgoCD/microk8s host onto the new
MS-01. This is **Phase 3.5** of the [build plan](./build-plan.md#phase-35--app-data-migration-);
do it only after the validation gate passes.

Principle: **old and new run in parallel; cut over only after validating; keep a
rollback path.** Migrated data is *copied*, never moved, so the source stays intact.

- **Migrate:** Plex (metadata/DB), Radarr, Sonarr, Prowlarr.
- **Fresh, no migration:** Overseerr, RomM, Home Assistant, Frigate.

---

## Plex

Plex keeps everything in its data directory. On the current host it's typically one of:
```
~/.local/share/Plex Media Server/
/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/
```

**1. Compact the databases first** (often shrinks ~100 GB of metadata by 20–30% and
reduces fragmentation before the copy):
```bash
cd "<Plex data dir>/Plug-in Support/Databases"
sqlite3 com.plexapp.plugins.library.db        "VACUUM;"
sqlite3 com.plexapp.plugins.library.blobs.db  "VACUUM;"
```

**2. Copy with attributes preserved.** A plain `cp` silently drops symlinks, hard
links, ACLs, and xattrs that Plex relies on:
```bash
rsync -aHAX --info=progress2 \
  "<Plex data dir>/" user@minis:/opt/plex/config/
```

**3. Fix ownership** to match the container UID/GID (LinuxServer images default to
1000:1000):
```bash
sudo chown -R 1000:1000 /opt/plex/
```

**4. Do NOT set `PLEX_CLAIM`.** The migrated data already contains a valid token;
`PLEX_CLAIM` is only for fresh installs. Point the pod at the migrated config dir and
it authenticates with the existing token.

**5. After first boot:** Settings → Troubleshooting → **Clean Bundles**, then **Empty
Trash**, then **Clean Metadata Bundles**. This clears stale cache references from the
old install path without touching metadata.

**6. Remote access:** with the [LAN + Tailnet model](./architecture.md#access-model),
leave Plex's own remote access off. (If you later need to share with non-Tailnet
users, expose Plex via Tailscale Funnel — a follow-up, not part of this migration.)

---

## *arr stack (Radarr, Sonarr, Prowlarr)

Each app stores everything under a single config directory — typically `~/.config/<app>/`,
or `/config` if already containerized.

**1. Copy each config dir** (same attribute-preserving rsync):
```bash
rsync -aHAX --info=progress2 ~/.config/radarr/   user@minis:/opt/radarr/config/
rsync -aHAX --info=progress2 ~/.config/sonarr/   user@minis:/opt/sonarr/config/
rsync -aHAX --info=progress2 ~/.config/prowlarr/ user@minis:/opt/prowlarr/config/
sudo chown -R 1000:1000 /opt/radarr /opt/sonarr /opt/prowlarr
```

**2. The key file is `config.xml`** in each — it holds the API key and the DB path
(`<DataFolder>`). Each app fixes the path on first start; if anything misbehaves,
confirm `<DataFolder>` matches the in-container path (`/config`) before starting.

**3. Verify inter-app URLs.** The whole download stack (SABnzbd + *arrs) shares the
Gluetun pod's network namespace, so the *arr↔SABnzbd/Prowlarr URLs stay `localhost`
and usually migrate as-is; only callers outside the pod (Overseerr) need new targets.
Update in each app's web UI after start (not by editing SQLite):

| Connection | Old | New |
|---|---|---|
| Radarr/Sonarr → download client | `localhost:8080` | `localhost:8080` — unchanged (same pod netns) |
| Radarr/Sonarr → Prowlarr | `localhost:9696` | `localhost:9696` — unchanged (same pod netns) |
| Overseerr → Radarr | `localhost:7878` | `http://gluetun.media.svc.cluster.local:7878` |
| Overseerr → Sonarr | `localhost:8989` | `http://gluetun.media.svc.cluster.local:8989` |

> From outside the pod, every download-stack app (SABnzbd and the *arrs) is reached
> at the **Gluetun** Service address on the app's port — there are no per-app
> Services for the download stack.

---

## Fresh-install apps

**Overseerr** and **RomM** start clean. After Overseerr is up, link it to Plex via
Plex OAuth (Settings → Plex → sign in) — the callback URL is tied to the new hostname,
so this must be done on the new instance regardless. **Home Assistant** and **Frigate**
are also fresh; HA needs `hostNetwork: true` for device discovery and hostPath mounts
for any Zigbee/Z-Wave USB stick.

---

## Parallel run → cutover → rollback

1. **Migrate while the old stack still runs.** rsync configs to the new node; the old
   stack keeps serving.
2. **Bring up new pods with NAS media mounts read-only initially.** Validate: Plex
   sees the full library and metadata; Quick Sync transcode works; *arr apps show
   their history; a test download flows end-to-end Prowlarr → Radarr → SABnzbd.
3. **Verify inter-app URLs** (intra-pod ones stay `localhost`; update Overseerr's
   Radarr/Sonarr targets); re-validate the test download.
4. **Cutover:** switch DNS / point Overseerr at the new stack; flip NAS mounts to
   read-write; **do a final rsync** to capture any config changes made through the UI
   during validation (new indexers, quality profiles — these live in the old SQLite
   and won't be in the first copy).
5. **Shut down the old stack.**
6. **Rollback path:** keep the old node intact and powered off (not wiped) for ~2
   weeks. If something surfaces post-cutover, the old config still exists to fall back
   to.

> The final rsync in step 4 is the most-forgotten step and the one most likely to
> cause "but I added that indexer!" confusion later. Don't skip it.
