# Home Assistant

Home Assistant deployment for Phase 4. It began as a fresh install; the deployment and
authenticated API-managed backup/restore path are operational. MQTT and Frigate
application integration still require final validation.

- `hostNetwork: true` keeps LAN discovery paths such as mDNS/Zeroconf available.
- State lives on local NVMe at `/opt/home-assistant/config`.
- The init container seeds `configuration.yaml` only when the PVC is empty so
  ingress reverse-proxy headers work on first boot.
- No Zigbee/Z-Wave USB device is mounted yet; add an explicit hostPath once the
  target device path is known.
- Frigate is connected through the internal Mosquitto broker. Add Home Assistant's
  MQTT integration with `mosquitto.mqtt.svc.cluster.local:1883`, then add the HACS
  Frigate integration with URL `http://frigate.frigate.svc.cluster.local:8971`.

Use `local-nvme` for app state. Device passthrough and host networking should be
documented in the manifest comments when added.
