# MQTT

Internal Mosquitto broker for Home Assistant integrations and Frigate events.

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
