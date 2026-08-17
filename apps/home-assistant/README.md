# Home Assistant

Home Assistant deployment for Phase 4. It began as a fresh install; the deployment,
authenticated API-managed backup/restore path, MQTT broker connection, HACS Frigate
integration, and real camera-event path are operational.

- `hostNetwork: true` keeps LAN discovery paths such as mDNS/Zeroconf available.
- State lives on local NVMe at `/opt/home-assistant/config`.
- Z-Wave JS UI runs beside Home Assistant and stores its configuration, security keys,
  logs, and controller backups at `/opt/zwave-js-ui/store`. It connects to the
  SLZB-MRW10U over `tcp://slzb-mrw10u.iot.matrix:6638`; no USB passthrough or host
  networking is required. The appliance is currently on Trusted/VLAN 30 and is planned
  to move to IoT/VLAN 60; this fixed DNS/TCP path does not depend on mDNS reflection.
- The repo copies of `configuration.yaml` and `automations.yaml` mirror the safe,
  recovery-relevant live YAML. The init container independently seeds either file when
  it is missing from the PVC. The recovery automation contains the live Frigate person
  detection notification for Charlie's iPhone; existing files are never overwritten,
  so later UI-managed changes remain authoritative.
- The Z-Wave JS UI is intentionally cluster-internal. Its control panel is available
  through a local port-forward, while Home Assistant uses its in-cluster WebSocket
  Service.
- Frigate is connected through the internal Mosquitto broker. Add Home Assistant's
  MQTT integration with `mosquitto.mqtt.svc.cluster.local:1883`, TCP transport, and
  TLS disabled. Use the Home Assistant-specific account from the SOPS-encrypted
  `apps/mqtt/mosquitto-auth.sops.yaml` Secret.
- Zigbee2MQTT publishes Home Assistant MQTT discovery through that existing MQTT
  integration. Do not add ZHA alongside it; both would contend for the same Zigbee
  coordinator socket. Zigbee2MQTT and its pairing workflow are documented in
  `apps/zigbee2mqtt/README.md`. Device pairing and MQTT discovery are operational,
  and the discovered devices are in active use by Home Assistant automations.
- Install HACS and its Frigate integration, then connect the integration to
  `https://frigate.worm.run` with the existing Frigate login. Do not use
  `http://frigate.frigate.svc.cluster.local:8971`: Frigate serves HTTPS on port 8971,
  and its certificate is valid for the ingress hostname rather than the Kubernetes
  Service DNS name.

## MQTT and Frigate integration closeout

Home Assistant, HACS, and the Frigate integration store their UI-managed state on the
Home Assistant PVC. Confirm a current Home Assistant backup and take the normal `/opt`
btrfs snapshot before starting.

This UI-managed state is the explicit exception to the repo's "changes are git
commits" rule. Home Assistant integrations, automations, dashboards, HACS, and similar
configuration are changed through Home Assistant and recovered from the Home
Assistant-aware Restic backup; Kubernetes deployment, storage, networking, and seed
configuration remain GitOps-managed here.

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

## Z-Wave JS integration

Z-Wave JS UI provides the server recommended for Home Assistant Container. The
Kubernetes deployment fixes the controller endpoint with `ZWAVE_PORT`; UI-managed
settings and Z-Wave security keys remain on the retained PVC and are protected by the
normal `/opt` backup path.

Before initial setup, confirm a current Home Assistant backup and take the normal
`/opt` btrfs snapshot. Then:

1. Reconcile the apps Kustomization and run
   `./runbooks/phase4/13-validate-zwave-js.sh`.
2. Open the Z-Wave JS UI locally:

   ```bash
   kubectl -n home-assistant port-forward svc/zwave-js-ui 8091:8091
   ```

   Browse to `http://127.0.0.1:8091`.
3. In **Settings → Z-Wave**, confirm the serial port is
   `tcp://slzb-mrw10u.iot.matrix:6638`. For a new Z-Wave network, generate all S0 and
   S2 security keys, save, and keep an additional copy in the password manager. Never
   add those keys to an unencrypted manifest.
4. In **Settings → Home Assistant**, enable the WS Server on port `3000` and save.
   MQTT is not needed for the native Home Assistant Z-Wave integration.
5. In Home Assistant, add the **Z-Wave** integration. Do not select a Supervisor app;
   use `ws://zwave-js-ui.home-assistant.svc.cluster.local:3000` as the server URL.
6. Rerun `./runbooks/phase4/13-validate-zwave-js.sh`, then include the first device and
   confirm its entities appear in Home Assistant.

Home Assistant's integration entry and Z-Wave JS UI's settings are UI/PVC-managed by
design. Back up the controller NVM after inclusions and before firmware or controller
changes.

Live validation passed on 2026-08-16: Z-Wave JS UI connected to the SLZB-MRW10U
controller, Home Assistant connected to the in-cluster WebSocket server, and an
included device produced entities in Home Assistant. Initial setup is therefore
complete; repeat the validator and take a fresh controller NVM backup after material
controller changes or additional inclusions. A fresh 40,960-byte NVM backup was
created on 2026-08-17; the validator now requires a non-empty backup no older than 30
days by default.

Use `local-nvme` for app state. Device passthrough and host networking should be
documented in the manifest comments when added.
