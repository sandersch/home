# Home Assistant

Home Assistant deployment for Phase 4. It began as a fresh install; the deployment,
authenticated API-managed backup/restore path, MQTT broker connection, HACS Frigate
integration, and real camera-event path are operational.

- `hostNetwork: true` keeps LAN discovery paths such as mDNS/Zeroconf available.
- State lives on local NVMe at `/opt/home-assistant/config`.
- The init container seeds `configuration.yaml` only when the PVC is empty so
  ingress reverse-proxy headers work on first boot.
- No Zigbee/Z-Wave USB device is mounted yet; add an explicit hostPath once the
  target device path is known.
- Frigate is connected through the internal Mosquitto broker. Add Home Assistant's
  MQTT integration with `mosquitto.mqtt.svc.cluster.local:1883`, TCP transport, and
  TLS disabled. Use the Home Assistant-specific account from the SOPS-encrypted
  `apps/mqtt/mosquitto-auth.sops.yaml` Secret.
- Install HACS and its Frigate integration, then connect the integration to
  `https://frigate.worm.run` with the existing Frigate login. Do not use
  `http://frigate.frigate.svc.cluster.local:8971`: Frigate serves HTTPS on port 8971,
  and its certificate is valid for the ingress hostname rather than the Kubernetes
  Service DNS name.

## MQTT and Frigate integration closeout

Home Assistant, HACS, and the Frigate integration store their UI-managed state on the
Home Assistant PVC. Confirm a current Home Assistant backup and take the normal `/opt`
btrfs snapshot before starting.

1. Extract the `MOSQUITTO_HOME_ASSISTANT_*` values from
   `apps/mqtt/mosquitto-auth.sops.yaml`. SOPS removes the encryption layer, but values
   under Kubernetes Secret `data` remain base64-encoded; decode each exactly once
   before entering it in Home Assistant. Do not save the decrypted Secret in the repo.
2. Configure MQTT with host `mosquitto.mqtt.svc.cluster.local`, port `1883`, TCP
   transport, TLS disabled, and discovery enabled. A unique client ID such as
   `home-assistant-minis` makes broker logs easier to interpret.
3. Install HACS using its Home Assistant Container procedure, restart Home Assistant,
   add the HACS integration, and complete the GitHub device authorization.
4. Install the Frigate integration from HACS, restart Home Assistant, and add it with
   URL `https://frigate.worm.run` and the existing Frigate login.
5. Run `./runbooks/phase4/12-validate-mqtt.sh`, then listen to `frigate/#` in Home
   Assistant while triggering a person event on `amcrest_105_50`.

Do not rerun the MQTT secret helper unless rotating credentials intentionally. A
Secret reconciliation does not restart Mosquitto or Frigate; after a rotation, perform
controlled restarts of both Deployments and update Home Assistant's broker login.

Live validation passed on 2026-07-18: authenticated publish/subscribe, anonymous and
bad-password rejection, retained Frigate availability, HA integration and entity
registration, valid HTTPS API reachability, and a real `amcrest_105_50` person event
with matching occupancy changes all succeeded.

Use `local-nvme` for app state. Device passthrough and host networking should be
documented in the manifest comments when added.
