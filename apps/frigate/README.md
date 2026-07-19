# Frigate

Frigate runs in its own namespace with `hostNetwork: true` so RTSP connections to the
isolated camera segment originate from the host's `cam0` address. Keep valuable state
on `local-nvme`, recordings on NAS NFS at `/mnt/frigate`, and cache/scratch data on
`topolvm-scratch`.

Quick Sync is exposed through Intel's GPU device plugin by requesting
`gpu.intel.com/i915: "1"`. The Coral uses a `/dev/bus/usb` hostPath and the container
runs privileged; an unprivileged diagnostic pod could see the device node but could not
initialize the EdgeTPU delegate.

Frigate reads `/config/config.yml` from the generated `frigate-config` ConfigMap. The
repo copy at `apps/frigate/config.yml` is the canonical source; Flux rolls the
Deployment when that file changes. The rest of `/config` remains backed by
`frigate-config-pvc` for Frigate state.

Camera RTSP credentials are stored in the committed SOPS-encrypted
`frigate.sops.yaml`. To provision another installation or intentionally rotate the
credentials, export the camera-specific values and rerun the helper:

```bash
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_USER=...
export FRIGATE_CAMERA_AMCREST_105_50_RTSP_PASSWORD=...
./runbooks/phase4/07-encrypt-frigate-secrets.sh
```

Do not rerun the helper during ordinary operation because it also rotates Frigate's
JWT secret. Generate or rotate MQTT credentials with
`./runbooks/phase4/11-encrypt-mqtt-secrets.sh`; that script writes the separate
`frigate-mqtt` Secret consumed by the Deployment. Additional cameras should use the
same camera-scoped pattern, for example
`FRIGATE_CAMERA_DRIVEWAY_105_51_RTSP_USER` and
`FRIGATE_CAMERA_DRIVEWAY_105_51_RTSP_PASSWORD`; the secret helper includes exported
matching pairs automatically.

Validate Coral USB and Intel VAAPI passthrough before declaring this workload ready.
