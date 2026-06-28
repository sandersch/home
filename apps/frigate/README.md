# Frigate

Frigate runs in its own namespace with `hostNetwork: true` so RTSP connections to the
isolated camera segment originate from the host's `cam0` address. Keep valuable state
on `local-nvme`, recordings on NAS NFS at `/mnt/frigate`, and cache/scratch data on
`topolvm-scratch`.

Before reconciling this app, generate real RTSP credentials:

```bash
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER=...
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD=...
./runbooks/phase4/07-encrypt-frigate-secrets.sh
```

The committed encrypted Secret is only a placeholder so the app tree can build before
the real camera credentials are available. Additional cameras should use the same
camera-scoped pattern, for example
`FRIGATE_CAMERA_DRIVEWAY_105_51_RTSP_USER` and
`FRIGATE_CAMERA_DRIVEWAY_105_51_RTSP_PASSWORD`; the secret helper includes exported
matching pairs automatically.

Validate Coral USB and Intel VAAPI passthrough before declaring this workload ready.
