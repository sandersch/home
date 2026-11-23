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
  only to `zigbee2mqtt/bridge/state`, `zigbee2mqtt/bridge/health`, and
  `zigbee2mqtt/+/availability`, and exposes the retained bridge state, Zigbee2MQTT's
  MQTT connection status, health timestamp, and per-device availability to
  Prometheus. The deployment override publishes health every minute; a critical
  alert fires when the combined bridge signal remains unhealthy for five minutes.
  A second critical alert fires when at least half of the tracked devices and groups
  stay unavailable for five minutes. That catches a radio that accepts commands but
  delivers nothing while the bridge still looks healthy.
- Separate critical blackbox TCP probes check the coordinator's Zigbee socket
  `slzb-mrw10u.iot.matrix:7638` and Z-Wave socket `slzb-mrw10u.iot.matrix:6638`
  every 30 seconds and use the shared `CriticalEndpointDown` rule after three
  minutes. This covers coordinator DNS, routing, appliance, and socket failures that
  the frontend and MQTT health signals can miss.

After Flux reconciles, run `./runbooks/phase4/14-validate-zigbee2mqtt.sh`. Then open
the frontend, enable joining only for the time needed to pair each device, give each
device a stable friendly name, and confirm its MQTT-discovered entities appear in
Home Assistant. Keep joining disabled otherwise.

Run `./runbooks/phase5/15-validate-zigbee2mqtt-monitoring.sh` after monitoring changes
and during periodic monitoring drills. The non-disruptive helper validates the live
critical ingress and Zigbee/Z-Wave coordinator TCP probes, MQTT exporter target,
bridge-health and device-availability metrics, and inactive Zigbee2MQTT/endpoint
alerts without publishing synthetic retained state.

The workload, coordinator connection, broker connection, frontend, exporter, and
monitoring paths passed live validation on 2026-08-16. Device pairing and Home
Assistant MQTT discovery are also complete, and discovered Zigbee devices have been
used successfully in Home Assistant automations.

## Coordinator firmware

The SLZB-MRW10U carries three pieces of firmware. Expected versions as of 2026-11-22:

| Component | Version | Reported by |
|---|---|---|
| SLZB-OS (appliance) | `v3.3.1`, update channel `release` | SLZB web UI, `http://slzb-mrw10u.iot.matrix/ha_info` (`sw_version`, `fw_channel`) |
| Zigbee radio, TI CC2674P10 | Z-Stack `20261113` | Zigbee2MQTT startup log (`Coordinator firmware version`), `ha_info` radio `chip_index` 1 |
| Z-Wave radio, Silicon Labs EFR32ZG23 | `20260402` (Z-Wave SDK 7.24.3) | Z-Wave JS UI controller info, `ha_info` radio `chip_index` 0 |

Firmware changes are attended, like k3s and chart upgrades. Keep the appliance on
the `release` channel with automatic updates off (both confirmed in the SLZB UI on
2026-11-22). Before changing any of the three,
request a fresh Zigbee2MQTT backup and a Z-Wave NVM backup, and plan for both radios
to drop. Afterwards, restart Zigbee2MQTT so it registers its endpoints with the
radio again, then run the Phase 4 Zigbee2MQTT and Z-Wave validators and the Phase 5
monitoring validator. Update the table in the same change.

A 2026-11-22 unattended update from the `dev` channel left the Zigbee radio
rejecting every send while the bridge still reported online. See the
[incident record](../../docs/operations.md#2026-11-22-zigbee-down-for-78-minutes-after-an-unattended-coordinator-firmware-update).
The Zigbee radio kept the `20261113` build from that update; it has run cleanly
since Zigbee2MQTT was restarted.

## Backups

Back up `coordinator_backup.json`, `database.db`, and `configuration.yaml` after
pairing devices and before coordinator firmware or Zigbee network changes. A fresh
coordinator/data backup was requested on 2026-08-17, producing a 2,321-byte
`coordinator_backup.json`; the Phase 4 validator now requires that file to be
non-empty and no older than 30 days by default.
