# MQTT

Internal Mosquitto broker for Home Assistant integrations, Frigate events, and
Zigbee2MQTT discovery/state traffic.

- No ingress is exposed; clients use `mosquitto.mqtt.svc.cluster.local:1883`.
- Broker persistence lives on local NVMe at `/opt/mosquitto/data`.
- The password file is generated at pod start from the SOPS-encrypted
  `mosquitto-auth` Secret. Do not commit plaintext MQTT credentials.

Generate or rotate credentials with:

```bash
./runbooks/phase4/11-encrypt-mqtt-secrets.sh
```

Use the generated Home Assistant username/password when adding the MQTT integration
in the Home Assistant UI.

Zigbee2MQTT has a separate SOPS-encrypted account in
`zigbee2mqtt-auth.sops.yaml`; the matching Secret in `apps/zigbee2mqtt/` is loaded
into that workload as configuration environment variables. Rotate the two copies
together.
