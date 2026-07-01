# Home Assistant

Fresh Home Assistant deployment for Phase 4.

- `hostNetwork: true` keeps LAN discovery paths such as mDNS/Zeroconf available.
- State lives on local NVMe at `/opt/home-assistant/config`.
- The init container seeds `configuration.yaml` only when the PVC is empty so
  ingress reverse-proxy headers work on first boot.
- No Zigbee/Z-Wave USB device is mounted yet; add an explicit hostPath once the
  target device path is known.

Use `local-nvme` for app state. Device passthrough and host networking should be
documented in the manifest comments when added.
