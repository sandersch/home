# Media

Media workload manifests will live here: Plex, Gluetun, SABnzbd, qBittorrent, the `*arr` stack,
Seerr, and RomM.

Stateful app config should use `local-nvme`; high-write scratch data should use
`topolvm-scratch`.

## Download stack

The first Phase 4 workload is `download-stack`: one pod containing Gluetun, SABnzbd,
qBittorrent, Prowlarr, Radarr, and Sonarr. It depends on a SOPS-encrypted
`download-stack/gluetun-mullvad.sops.yaml` Secret for WireGuard values and a plaintext
`download-stack/configmap.yaml` for non-secret Gluetun config.

```bash
./runbooks/phase4/01-encrypt-download-secrets.sh
```

Do not reconcile or commit the app stack without that encrypted Secret included in
`download-stack/kustomization.yaml`; the Deployment references `gluetun-mullvad`.
If `gluetun-mullvad.sops.yaml` was generated before the ConfigMap split, regenerate
it with the script so the Secret contains only `WIREGUARD_PRIVATE_KEY` and
`WIREGUARD_ADDRESSES`.
