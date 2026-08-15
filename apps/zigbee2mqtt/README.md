# Zigbee2MQTT

Zigbee2MQTT runs as a dedicated critical workload and bridges the network-attached
SLZB-MRW10U Zigbee coordinator into the existing authenticated Mosquitto broker.

- The TI CC2674P10 Zigbee radio is `tcp://slzb-mrw10u.iot.matrix:7638` with the
  `zstack` adapter. Port `6638` is the separate Z-Wave radio used by Z-Wave JS UI.
- Retained state, device database, coordinator backups, and runtime-managed
  configuration live at `/opt/zigbee2mqtt/data` and are covered by the normal
  `/opt` backup path.
- The seed config creates a fresh channel 15 network with random PAN IDs and network
  key on first start. It is copied only when `configuration.yaml` does not exist;
  Zigbee2MQTT's runtime/UI changes on the PVC remain authoritative afterward.
- Home Assistant discovery is enabled over the existing MQTT integration. Do not
  add ZHA again: only one application may own the coordinator socket.
- The frontend is available at `https://zigbee2mqtt.worm.run` and requires the token
  in `zigbee2mqtt-auth.sops.yaml`. No public ingress is exposed.

After Flux reconciles, run `./runbooks/phase4/14-validate-zigbee2mqtt.sh`. Then open
the frontend, enable joining only for the time needed to pair each device, give each
device a stable friendly name, and confirm its MQTT-discovered entities appear in
Home Assistant. Keep joining disabled otherwise.

Back up `coordinator_backup.json`, `database.db`, and `configuration.yaml` after
pairing devices and before coordinator firmware or Zigbee network changes.
