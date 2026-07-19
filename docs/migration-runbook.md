# Migration Runbook — Plex & *arr

Moving existing application state from the current ArgoCD/microk8s host onto the new
MS-01. This is **Phase 3.5** of the [build plan](./build-plan.md#phase-35--app-data-migration-);
do it only after the validation gate passes.

For the current stopped-host archive path, use the executable host-side scripts in
[`runbooks/phase3.5`](../runbooks/phase3.5/).

Principle: migrated data is *copied*, never moved, so the source stays intact. When
the old stack is still running, Phase 3.5 is only a warm pre-copy and Phase 4 needs a
final quiesced rsync. In the current stopped-host archive flow, Phase 3.5 is already
the final quiesced copy.

- **Migrate:** Plex (metadata/DB), Radarr, Sonarr, Prowlarr.
- **Fresh, no migration:** Seerr, RomM, Home Assistant, Frigate.

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

**3. Verify inter-app URLs.** The whole download stack (SABnzbd + qBittorrent + *arrs)
shares the Gluetun pod's network namespace, so the *arr↔SABnzbd/Prowlarr URLs stay
`localhost` and usually migrate as-is; only callers outside the pod (Seerr) need new
targets. qBittorrent is a fresh download client added after first boot.
Update in each app's web UI after start (not by editing SQLite):

| Connection | Old | New |
|---|---|---|
| Radarr/Sonarr → SABnzbd | `localhost:8080` | `localhost:8080` — unchanged (same pod netns) |
| Radarr/Sonarr → qBittorrent | N/A | `localhost:8090` — add after first qBittorrent login |
| Radarr/Sonarr → Prowlarr | `localhost:9696` | `localhost:9696` — unchanged (same pod netns) |
| Seerr → Radarr | `localhost:7878` | `http://gluetun.media.svc.cluster.local:7878` |
| Seerr → Sonarr | `localhost:8989` | `http://gluetun.media.svc.cluster.local:8989` |

> From outside the pod, every download-stack app (SABnzbd, qBittorrent, and the
> *arrs) is reached at the **Gluetun** Service address on the app's port — there are
> no per-app Services for the download stack.

---

## Fresh-install apps

**Seerr** and **RomM** start clean. After Seerr is up, link it to Plex via
Plex OAuth (Settings → Plex → sign in) — the callback URL is tied to the new hostname,
so this must be done on the new instance regardless. **Home Assistant** and **Frigate**
are also fresh; HA needs `hostNetwork: true` for device discovery. Z-Wave JS UI uses
the network-attached SLZB-MRW10U at `tcp://slzb-mrw10u.iot.matrix:6638`, so it needs
no hostPath device mount.

---

## Phase 3.5 copy, then Phase 4 validation

1. **Phase 3.5 stopped-host copy:** run `runbooks/phase3.5/run-all.sh` on `minis`.
   It copies the archive from `/mnt/media/to_archive/config` into `/opt/...` and
   validates the copied SQLite DBs.
2. **Phase 4: deploy new pods using the copied data.** Keep NAS media mounts
   read-only initially where practical. Validate: Plex sees the full library and
   metadata; Quick Sync transcode works; *arr apps show their history; VPN egress is
   the Mullvad exit IP; a test download flows end-to-end Prowlarr → Radarr → SABnzbd.
3. **Still in Phase 4: verify inter-app URLs** (intra-pod ones stay `localhost`;
   update Seerr's Radarr/Sonarr targets); re-validate the test download.
4. **After validation:** keep the old stopped hosts or archive intact for ~2 weeks.
   If something surfaces post-migration, the old config still exists to fall back to.

If you ever repeat this with the old stack still running, do a final quiesced rsync
during Phase 4 cutover before declaring the new stack authoritative.
