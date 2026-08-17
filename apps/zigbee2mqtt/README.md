# Zigbee2MQTT

Zigbee2MQTT runs as a dedicated critical workload and bridges the network-attached
SLZB-MRW10U Zigbee coordinator into the existing authenticated Mosquitto broker.

- The TI CC2674P10 Zigbee radio is `tcp://slzb-mrw10u.iot.matrix:7638` with the
  `zstack` adapter. Port `6638` is the separate Z-Wave radio used by Z-Wave JS UI.
  The appliance is currently on Trusted/VLAN 30 and is planned to move to IoT/VLAN 60;
  the stable DNS/TCP connection does not require mDNS reflection.
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
- A critical-priority MQTT exporter reuses that encrypted broker account, subscribes
  only to `zigbee2mqtt/bridge/state` and `zigbee2mqtt/bridge/health`, and exposes the
  retained bridge state, Zigbee2MQTT's MQTT connection status, and health timestamp
  to Prometheus. The deployment override publishes health every minute; a critical
  alert fires when the combined signal remains unhealthy for five minutes.
- A separate critical blackbox TCP probe checks
  `slzb-mrw10u.iot.matrix:7638` every 30 seconds and uses the shared
  `CriticalEndpointDown` rule after three minutes. This covers coordinator DNS,
  routing, appliance, and socket failures that the frontend and MQTT health signals
  can miss.

After Flux reconciles, run `./runbooks/phase4/14-validate-zigbee2mqtt.sh`. Then open
the frontend, enable joining only for the time needed to pair each device, give each
device a stable friendly name, and confirm its MQTT-discovered entities appear in
Home Assistant. Keep joining disabled otherwise.

Run `./runbooks/phase5/15-validate-zigbee2mqtt-monitoring.sh` after monitoring changes
and during periodic monitoring drills. The non-disruptive helper validates the live
critical ingress and coordinator TCP probes, MQTT exporter target and metrics, and
inactive bridge-health/endpoint alerts without publishing synthetic retained state.

The workload, coordinator connection, broker connection, frontend, exporter, and
monitoring paths passed live validation on 2026-08-16. Device pairing and Home
Assistant MQTT discovery are also complete, and discovered Zigbee devices have been
used successfully in Home Assistant automations.

Back up `coordinator_backup.json`, `database.db`, and `configuration.yaml` after
pairing devices and before coordinator firmware or Zigbee network changes.
