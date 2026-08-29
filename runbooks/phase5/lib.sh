#!/usr/bin/env bash
# Phase 5 helpers.
#
# Phase 5 starts with backups, then adds observability.

# shellcheck source=runbooks/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# shellcheck disable=SC2034
PHASE5_MONITORING_DIR="$REPO_ROOT/infrastructure/monitoring"
# shellcheck disable=SC2034
PHASE5_OBSERVABILITY_CONFIG_DIR="$PHASE5_MONITORING_DIR/configs"
# shellcheck disable=SC2034
PHASE5_NUT_EXPORTER_CONFIG="$PHASE5_OBSERVABILITY_CONFIG_DIR/nut-exporter.yaml"
# shellcheck disable=SC2034
PHASE5_NUT_EXPORTER_DASHBOARD="$PHASE5_OBSERVABILITY_CONFIG_DIR/nut-exporter-dashboard.json"
# shellcheck disable=SC2034
PHASE5_DEADMANS_SNITCH_DIR="$PHASE5_OBSERVABILITY_CONFIG_DIR/deadmanssnitch"
# shellcheck disable=SC2034
PHASE5_DEADMANS_SNITCH_SECRET="$PHASE5_DEADMANS_SNITCH_DIR/deadmanssnitch.sops.yaml"
# shellcheck disable=SC2034
PHASE5_PUSHOVER_DIR="$PHASE5_OBSERVABILITY_CONFIG_DIR/pushover"
# shellcheck disable=SC2034
PHASE5_PUSHOVER_CONFIG="$PHASE5_PUSHOVER_DIR/alertmanagerconfig.yaml"
# shellcheck disable=SC2034
PHASE5_PUSHOVER_SECRET="$PHASE5_PUSHOVER_DIR/pushover.sops.yaml"
# shellcheck disable=SC2034
PHASE5_GRAFANA_SECRET="$PHASE5_MONITORING_DIR/base/grafana-admin.sops.yaml"
# shellcheck disable=SC2034
PHASE5_RESTIC_SECRET="$PHASE5_MONITORING_DIR/restic-nas.sops.yaml"
# shellcheck disable=SC2034
PHASE5_RESTIC_B2_SECRET="$PHASE5_MONITORING_DIR/restic-b2.sops.yaml"
# shellcheck disable=SC2034
PHASE5_ROMM_SECRET="$REPO_ROOT/apps/media/romm/romm.sops.yaml"
# shellcheck disable=SC2034
PHASE5_BACKUP_MOUNT="/mnt/backups"
# shellcheck disable=SC2034
PHASE5_BACKUP_SOURCE="/dev/mapper/hoardvg-backuplv"
# shellcheck disable=SC2034
PHASE5_BACKUP_UUID="cc1cedb8-ef22-44b5-b1d0-5ca020d72669"

require_flux_cli() {
  if command -v flux >/dev/null; then
    ok "flux CLI present"
    return 0
  fi
  die "flux CLI is required for Phase 5 validation"
}

assert_phase5_backup_tree() {
  local f
  for f in \
    clusters/minis/monitoring.yaml \
    infrastructure/monitoring/kustomization.yaml \
    infrastructure/monitoring/base/namespace.yaml \
    infrastructure/monitoring/restic-nas-config.yaml \
    infrastructure/monitoring/restic-nas-cronjob.yaml \
    infrastructure/monitoring/restic-b2-cronjob.yaml \
    containers/restic-backup/Containerfile \
    apps/media/romm/mariadb-service.yaml; do
    [ -f "$REPO_ROOT/$f" ] || die "missing Phase 5 backup file: $f"
  done
  ok "Phase 5 backup tree is present"
}

assert_phase5_observability_builds() {
  local target
  for target in \
    infrastructure/monitoring/base \
    infrastructure/monitoring/controllers \
    infrastructure/monitoring/configs \
    clusters/minis; do
    kustomize build "$REPO_ROOT/$target" >/dev/null
    ok "kustomize build $target"
  done
}

assert_phase5_observability_invariants() {
  yq -e '.spec.chart.spec.version == "87.17.0" and
    .spec.install.crds == "CreateReplace" and
    .spec.upgrade.crds == "CreateReplace"' \
    "$PHASE5_MONITORING_DIR/controllers/kube-prometheus-stack.yaml" >/dev/null \
    || die "kube-prometheus-stack version or CRD policy changed unexpectedly"
  yq -e '.spec.chart.spec.version == "11.15.1"' \
    "$PHASE5_OBSERVABILITY_CONFIG_DIR/blackbox-exporter.yaml" >/dev/null \
    || die "blackbox exporter version changed unexpectedly"
  yq -e 'select(.kind == "Probe" and .metadata.name == "critical-ingress") |
    .spec.targets.staticConfig.static ==
      ["https://home-assistant.worm.run", "https://frigate.worm.run",
       "https://zigbee2mqtt.worm.run"]' \
    "$PHASE5_OBSERVABILITY_CONFIG_DIR/blackbox-probes.yaml" >/dev/null \
    || die "critical ingress blackbox targets changed unexpectedly"
  yq -e 'select(.kind == "Probe" and .metadata.name == "mqtt") |
    .spec.targets.staticConfig.static == ["mosquitto.mqtt.svc.cluster.local:1883"]' \
    "$PHASE5_OBSERVABILITY_CONFIG_DIR/blackbox-probes.yaml" >/dev/null \
    || die "MQTT blackbox target changed unexpectedly"
  # shellcheck disable=SC2016 # $pod/$container are yq variables, not shell variables.
  yq -e '
    select(.kind == "Probe" and .metadata.name == "zigbee-coordinator") |
    .spec.interval == "30s" and
    .spec.jobName == "blackbox-zigbee-coordinator" and
    .spec.module == "tcp_connect" and
    .spec.scrapeTimeout == "10s" and
    .spec.targets.staticConfig.labels.probe_scope == "zigbee-coordinator" and
    .spec.targets.staticConfig.labels.service_tier == "critical" and
    .spec.targets.staticConfig.static == ["slzb-mrw10u.iot.matrix:7638"]
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/blackbox-probes.yaml" >/dev/null \
    || die "Zigbee coordinator critical TCP probe changed unexpectedly"
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[];
      .name == "homelab.blackbox" and
      any(.rules[];
        .alert == "CriticalEndpointDown" and
        .expr == "probe_success{service_tier=\"critical\"} == 0" and
        .for == "3m" and
        .labels.severity == "critical"))
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "critical blackbox alert expression, delay, or severity changed unexpectedly"
  yq -e '
    select(.kind == "Deployment" and .metadata.name == "zigbee2mqtt") |
    any(.spec.template.spec.containers[];
      .name == "zigbee2mqtt" and
      any(.env[];
        .name == "ZIGBEE2MQTT_CONFIG_HEALTH_INTERVAL" and .value == "1"))
  ' "$REPO_ROOT/apps/zigbee2mqtt/deployment.yaml" >/dev/null \
    || die "Zigbee2MQTT no longer publishes health at the expected one-minute interval"
  # shellcheck disable=SC2016 # $pod/$container are jq variables, not shell variables.
  yq -e '
    select(.kind == "Deployment" and .metadata.name == "zigbee2mqtt-mqtt-exporter") |
    .spec.template.spec as $pod |
    $pod.priorityClassName == "homelab-critical" and
    $pod.automountServiceAccountToken == false and
    $pod.securityContext.runAsNonRoot == true and
    $pod.securityContext.seccompProfile.type == "RuntimeDefault" and
    ($pod.containers[0] as $container |
      # renovate: datasource=docker depName=kpetrem/mqtt-exporter
      $container.image == "kpetrem/mqtt-exporter:1.12.1@sha256:dca3255f35310f6ceb80ed1de94eebd1fe9def7aacaec4107fe37cdaa9eb3be0" and
      $container.livenessProbe.httpGet.path == "/metrics" and
      $container.readinessProbe.httpGet.path == "/metrics" and
      $container.resources.requests.cpu == "25m" and
      $container.resources.requests.memory == "64Mi" and
      $container.resources.limits.cpu == "100m" and
      $container.resources.limits.memory == "128Mi" and
      $container.securityContext.allowPrivilegeEscalation == false and
      $container.securityContext.readOnlyRootFilesystem == true and
      any($container.env[];
        .name == "MQTT_ADDRESS" and
        .value == "mosquitto.mqtt.svc.cluster.local") and
      any($container.env[];
        .name == "MQTT_TOPIC" and
        .value == "zigbee2mqtt/bridge/state,zigbee2mqtt/bridge/health") and
      any($container.env[];
        .name == "MQTT_USERNAME" and
        .valueFrom.secretKeyRef.name == "zigbee2mqtt-auth" and
        .valueFrom.secretKeyRef.key == "ZIGBEE2MQTT_CONFIG_MQTT_USER") and
      any($container.env[];
        .name == "MQTT_PASSWORD" and
        .valueFrom.secretKeyRef.name == "zigbee2mqtt-auth" and
        .valueFrom.secretKeyRef.key == "ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD"))
  ' "$REPO_ROOT/apps/zigbee2mqtt/mqtt-exporter.yaml" >/dev/null \
    || die "Zigbee2MQTT MQTT exporter image, topics, credentials, resources, probes, or security settings changed unexpectedly"
  yq -e '
    select(.kind == "ServiceMonitor" and .metadata.name == "zigbee2mqtt-mqtt-health") |
    .spec.namespaceSelector.matchNames == ["zigbee2mqtt"] and
    .spec.endpoints[0].port == "metrics" and
    .spec.endpoints[0].path == "/metrics" and
    .spec.endpoints[0].interval == "30s" and
    .spec.endpoints[0].scrapeTimeout == "10s" and
    any(.spec.endpoints[0].metricRelabelings[];
      .sourceLabels == ["__name__"] and
      .regex == "mqtt_(state|response_time|mqtt_connected)" and
      .action == "keep")
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/zigbee2mqtt-mqtt-health.yaml" >/dev/null \
    || die "Zigbee2MQTT MQTT health ServiceMonitor changed unexpectedly"
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[].rules[];
      .alert == "Zigbee2MQTTBridgeUnhealthy" and
      .for == "5m" and
      .labels.severity == "critical" and
      (.expr | contains("mqtt_state{topic=\"zigbee2mqtt_bridge_state\"} == 0")) and
      (.expr | contains("mqtt_mqtt_connected{topic=\"zigbee2mqtt_bridge_health\"} == 0")) and
      (.expr | contains("mqtt_response_time{topic=\"zigbee2mqtt_bridge_health\"} / 1000")) and
      (.expr | contains("> 5 * 60")) and
      (.expr | contains("absent(mqtt_response_time")) and
      (.expr | contains("kube_deployment_status_replicas_available")))
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "Zigbee2MQTT MQTT bridge-health alert changed unexpectedly"
  yq -e '.resources | index("zigbee2mqtt-mqtt-health.yaml") != null' \
    "$PHASE5_OBSERVABILITY_CONFIG_DIR/kustomization.yaml" >/dev/null \
    || die "Zigbee2MQTT MQTT health ServiceMonitor is not included in monitoring-configs"
  # shellcheck disable=SC2016 # $pod/$container are jq variables, not shell variables.
  yq -e '
    select(.kind == "Deployment" and .metadata.name == "nut-exporter") |
    .spec.template.spec as $pod |
    $pod.priorityClassName == "homelab-standard" and
    $pod.automountServiceAccountToken == false and
    $pod.securityContext.runAsNonRoot == true and
    $pod.securityContext.seccompProfile.type == "RuntimeDefault" and
    ($pod.containers[0] as $container |
      # renovate: datasource=docker depName=ghcr.io/druggeri/nut_exporter
      $container.image == "ghcr.io/druggeri/nut_exporter:3.3.0@sha256:276460d141c732772f8b1fcd785a7de272473e6d39fd85c32b163efc2999cb9a" and
      $container.livenessProbe.httpGet.path == "/metrics" and
      $container.readinessProbe.httpGet.path == "/metrics" and
      $container.resources.requests.cpu == "20m" and
      $container.resources.requests.memory == "32Mi" and
      $container.resources.limits.cpu == "100m" and
      $container.resources.limits.memory == "64Mi" and
      $container.securityContext.allowPrivilegeEscalation == false and
      $container.securityContext.readOnlyRootFilesystem == true and
      any($container.env[];
        .name == "NUT_EXPORTER_SERVER" and .value == "10.137.20.5") and
      any($container.env[];
        .name == "NUT_EXPORTER_SERVERPORT" and .value == "3493") and
      any($container.env[];
        .name == "NUT_EXPORTER_VARIABLES" and
        (.value | contains("battery.runtime")) and
        (.value | contains("ups.status"))))
  ' "$PHASE5_NUT_EXPORTER_CONFIG" >/dev/null \
    || die "nut-exporter image, endpoint, resources, probes, or security settings changed unexpectedly"
  yq -e '
    select(.kind == "ServiceMonitor" and .metadata.name == "nut-exporter") |
    .spec.endpoints[0].port == "http" and
    .spec.endpoints[0].path == "/ups_metrics" and
    .spec.endpoints[0].interval == "30s" and
    .spec.endpoints[0].scrapeTimeout == "10s" and
    .spec.endpoints[0].params.ups == ["cp1500"] and
    any(.spec.endpoints[0].relabelings[];
      .sourceLabels == ["__param_ups"] and .targetLabel == "ups")
  ' "$PHASE5_NUT_EXPORTER_CONFIG" >/dev/null \
    || die "nut-exporter ServiceMonitor no longer scrapes or labels cp1500 at the expected interval"
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[];
      .name == "homelab.ups" and
      any(.rules[];
        .alert == "UPSOnBattery" and
        .expr == "network_ups_tools_ups_status{ups=\"cp1500\",flag=\"OB\"} == 1" and
        .for == "1m" and
        .labels.severity == "critical"))
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "UPS on-battery alert expression, delay, or severity changed unexpectedly"
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[].rules[];
      .alert == "ResticLocalBackupOverdue" and
      .for == "15m" and
      .labels.severity == "critical" and
      (.expr | contains("cronjob=\"restic-nas-backup\""))) and
    any(.spec.groups[].rules[];
      .alert == "BulkStorageMountSetIncomplete" and
      .for == "5m" and
      .labels.severity == "critical" and
      (.expr | contains("device=\"/dev/mapper/hoardvg-medialv\",fstype=\"ext4\",mountpoint=\"/mnt/media\"")) and
      (.expr | contains("device=\"/dev/mapper/hoardvg-games\",fstype=\"ext4\",mountpoint=\"/mnt/games\"")) and
      (.expr | contains("device=\"/dev/mapper/hoardvg-frigate\",fstype=\"ext4\",mountpoint=\"/mnt/frigate\"")) and
      (.expr | contains("device=\"/dev/mapper/hoardvg-backuplv\",fstype=\"ext4\",mountpoint=\"/mnt/backups\""))) and
    any(.spec.groups[].rules[];
      .alert == "BulkStorageFilesystemDeviceError" and
      .for == "5m" and
      .labels.severity == "critical")
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "local backup or direct-attached bulk-storage alerts changed unexpectedly"
  # NFSServerDown must NOT regain an absent() arm and NFSDCollectorFailing must keep its
  # probe gate: without both, every host that has not run runbooks/nfs-exports/ pages
  # during each rebuild (measured on the live cluster before the gates were added).
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[];
      .name == "homelab.nfs" and
      any(.rules[];
        .alert == "NFSServerDown" and
        .for == "5m" and
        .labels.severity == "warning" and
        (.expr | contains("node_nfsd_server_threads == 0")) and
        (.expr | contains("absent") | not)) and
      any(.rules[];
        .alert == "NFSLegacyVersionServed" and
        .labels.severity == "warning" and
        (.expr | contains("node_nfsd_requests_total{proto!=\"4\"}"))) and
      any(.rules[];
        .alert == "NFSDCollectorFailing" and
        .for == "15m" and
        .labels.severity == "warning" and
        (.expr | contains("absent(node_scrape_collector_success{collector=\"nfsd\"})")) and
        (.expr | contains("node_scrape_collector_success{collector=\"nfsd\"} == 0")) and
        (.expr | contains("and on() probe_success{probe_scope=\"nfs\"} == 1"))))
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "the homelab.nfs export alerts changed unexpectedly"
  yq -e '
    select(.kind == "Probe" and .metadata.name == "nfs") |
    .spec.module == "tcp_connect" and
    .spec.jobName == "blackbox-nfs" and
    .spec.targets.staticConfig.labels.probe_scope == "nfs" and
    (.spec.targets.staticConfig.static | index("10.137.20.5:2049") != null)
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/blackbox-probes.yaml" >/dev/null \
    || die "the NFS export blackbox probe target, module, or scope changed unexpectedly"
  yq -e '
    select(.kind == "PrometheusRule" and .metadata.name == "homelab-alerts") |
    any(.spec.groups[].rules[];
      .alert == "RaidCheckStalled" and
      .for == "15m" and
      .labels.severity == "warning" and
      (.expr | contains("node_md_state{device=\"md3\",state=\"check\"} == 1")) and
      (.expr | contains("changes(node_md_blocks_synced{device=\"md3\"}[30m]) == 0")))
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/alert-rules.yaml" >/dev/null \
    || die "RAID check-stall alert expression, delay, or severity changed unexpectedly"
  jq -e '
    .uid == "nut-exporter" and
    .title == "UPS / NUT — CP1500" and
    .editable == false and
    .refresh == "30s" and
    all(.panels[]; .datasource.uid == "prometheus") and
    ([.panels[].targets[]?.expr] | join(" ") |
      contains("network_ups_tools_ups_status") and
      contains("network_ups_tools_battery_charge") and
      contains("network_ups_tools_battery_runtime") and
      contains("network_ups_tools_ups_load"))
  ' "$PHASE5_NUT_EXPORTER_DASHBOARD" >/dev/null \
    || die "nut-exporter Grafana dashboard UID, datasource, refresh, or core panels changed unexpectedly"
  yq -e '
    .resources | index("nut-exporter.yaml") != null
  ' "$PHASE5_OBSERVABILITY_CONFIG_DIR/kustomization.yaml" >/dev/null \
    || die "nut-exporter resources are not included in monitoring-configs"
  kustomize build "$PHASE5_OBSERVABILITY_CONFIG_DIR" \
    | yq -e '
        select(.kind == "ConfigMap" and .metadata.name == "nut-exporter-dashboard") |
        .metadata.namespace == "monitoring" and
        .metadata.labels.grafana_dashboard == "1" and
        (.data | has("nut-exporter-dashboard.json"))
      ' >/dev/null \
    || die "nut-exporter dashboard ConfigMap is not rendered for Grafana discovery"
  yq -e '.data["admin-password"] | startswith("ENC[AES256_GCM")' \
    "$PHASE5_GRAFANA_SECRET" >/dev/null \
    || die "Grafana administrator password is missing or not SOPS-encrypted"
  ok "observability versions, probes, Zigbee2MQTT/UPS/RAID/storage alerts, dashboard, and encrypted Grafana credentials are intact"
}

assert_phase5_pushover_invariants() {
  local rendered="$1" component_active secret_included

  [ -f "$PHASE5_PUSHOVER_CONFIG" ] || die "missing dormant Pushover AlertmanagerConfig"
  [ -f "$PHASE5_PUSHOVER_DIR/kustomization.yaml" ] || die "missing Pushover kustomization"
  kustomize build "$PHASE5_PUSHOVER_DIR" >/dev/null

  yq -e '
    .apiVersion == "monitoring.coreos.com/v1alpha1" and
    .kind == "AlertmanagerConfig" and
    .metadata.name == "pushover" and
    .metadata.namespace == "monitoring" and
    .spec.route.groupWait == "30s" and
    .spec.route.repeatInterval == "12h" and
    any(.spec.route.matchers[];
      .name == "alertname" and .matchType == "!=" and .value == "Watchdog") and
    any(.spec.route.matchers[];
      .name == "severity" and .matchType == "=~" and .value == "^(warning|critical)$") and
    any(.spec.route.routes[];
      .receiver == "pushover-critical" and
      any(.matchers[];
        .name == "severity" and .matchType == "=" and .value == "critical"))
  ' "$PHASE5_PUSHOVER_CONFIG" >/dev/null \
    || die "Pushover must route only warning/critical alerts and explicitly exclude Watchdog"

  yq -e '
    (.spec.receivers[] | select(.name == "pushover-warning") |
      .pushoverConfigs[0].sendResolved == true and
      .pushoverConfigs[0].priority == "{{ if eq .Status \"firing\" }}0{{ else }}-1{{ end }}" and
      .pushoverConfigs[0].url == "https://grafana.worm.run" and
      .pushoverConfigs[0].userKey == {"key": "user-key", "name": "pushover"} and
      .pushoverConfigs[0].token == {"key": "api-token", "name": "pushover"}) and
    (.spec.receivers[] | select(.name == "pushover-critical") |
      .pushoverConfigs[0].sendResolved == true and
      .pushoverConfigs[0].priority == "{{ if eq .Status \"firing\" }}1{{ else }}-1{{ end }}" and
      .pushoverConfigs[0].url == "https://grafana.worm.run" and
      .pushoverConfigs[0].userKey == {"key": "user-key", "name": "pushover"} and
      .pushoverConfigs[0].token == {"key": "api-token", "name": "pushover"})
  ' "$PHASE5_PUSHOVER_CONFIG" >/dev/null \
    || die "Pushover priorities, recovery delivery, link, or Secret selectors changed unexpectedly"

  component_active=0
  secret_included=0
  if yq -e '.resources | index("pushover") != null' \
    "$PHASE5_OBSERVABILITY_CONFIG_DIR/kustomization.yaml" >/dev/null; then
    component_active=1
  fi
  if yq -e '.resources | index("pushover.sops.yaml") != null' \
    "$PHASE5_PUSHOVER_DIR/kustomization.yaml" >/dev/null; then
    secret_included=1
  fi

  if [ -f "$PHASE5_PUSHOVER_SECRET" ]; then
    [ "$component_active" -eq 1 ] && [ "$secret_included" -eq 1 ] \
      || die "the Pushover Secret exists but the complete component is not activated"
    grep -q '^sops:' "$PHASE5_PUSHOVER_SECRET" \
      || die "$PHASE5_PUSHOVER_SECRET is not SOPS-encrypted"
    yq -e '
      (.data["user-key"] | startswith("ENC[AES256_GCM")) and
      (.data["api-token"] | startswith("ENC[AES256_GCM"))
    ' "$PHASE5_PUSHOVER_SECRET" >/dev/null \
      || die "Pushover credentials are missing or not SOPS-encrypted"
  else
    [ "$component_active" -eq 0 ] && [ "$secret_included" -eq 0 ] \
      || die "Pushover is activated without its SOPS-encrypted Secret"
  fi

  kustomize build "$PHASE5_OBSERVABILITY_CONFIG_DIR" >"$rendered"
  if [ "$component_active" -eq 1 ]; then
    yq -e 'select(.kind == "Secret" and .metadata.name == "pushover")' "$rendered" >/dev/null \
      || die "the activated Pushover Secret is missing from rendered monitoring configs"
    yq -e 'select(.kind == "AlertmanagerConfig" and .metadata.name == "pushover")' "$rendered" >/dev/null \
      || die "the activated Pushover AlertmanagerConfig is missing from rendered monitoring configs"
    ok "Pushover is activated with encrypted credentials and explicit 0/1/-1 priorities"
  else
    if yq -e 'select(.kind == "Secret" and .metadata.name == "pushover")' "$rendered" >/dev/null; then
      die "the dormant Pushover Secret unexpectedly renders"
    fi
    if yq -e 'select(.kind == "AlertmanagerConfig" and .metadata.name == "pushover")' "$rendered" >/dev/null; then
      die "the dormant Pushover AlertmanagerConfig unexpectedly renders"
    fi
    ok "Pushover is dormant until its encrypted Secret is generated"
  fi
}

assert_phase5_backup_invariants() {
  local rendered="$1"

  kustomize build "$PHASE5_MONITORING_DIR" >"$rendered"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-nas-backup") |
    .spec.schedule == "15 3 * * *" and
    .spec.timeZone == "America/Chicago" and
    .spec.suspend != true and
    .spec.jobTemplate.spec.activeDeadlineSeconds == 3600' "$rendered" >/dev/null \
    || die "local Restic CronJob schedule or deadline changed unexpectedly"
  yq -e 'select(.kind == "ConfigMap" and .metadata.name == "restic-nas-config") |
    .data.RESTIC_REPOSITORY == "/repo/nas/opt" and
    .data.RESTIC_TARGET_TAG == "nas" and
    .data.RESTIC_KEEP_DAILY == "14" and
    .data.RESTIC_KEEP_WEEKLY == "8" and
    .data.RESTIC_KEEP_MONTHLY == "12" and
    .data.BACKUP_CONTRACT_VERSION == "2" and
    (.data.REQUIRED_SQLITE_DATABASES | split("\n") | length) == 8 and
    (.data.REQUIRED_SQLITE_DATABASES | contains("com.plexapp.plugins.library.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("com.plexapp.plugins.library.blobs.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("frigate/config/frigate.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("home-assistant/config/home-assistant_v2.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("prowlarr/config/prowlarr.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("radarr/config/radarr.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("sonarr/config/sonarr.db")) and
    (.data.REQUIRED_SQLITE_DATABASES | contains("seerr/config/db/db.sqlite3"))' "$rendered" >/dev/null \
    || die "local repository, retention policy, or required export contract changed unexpectedly"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-nas-backup") |
    any(.spec.jobTemplate.spec.template.spec.volumes[];
      .name == "backups" and .hostPath.path == "/mnt/backups")' "$rendered" >/dev/null \
    || die "local Restic CronJob no longer mounts /mnt/backups"
  yq -e '
    select(.kind == "CronJob" and
      (.metadata.name == "restic-nas-backup" or .metadata.name == "restic-b2-backup")) |
    .spec.jobTemplate.spec.template.spec as $pod |
    $pod.nodeSelector."kubernetes.io/hostname" == "minis" and
    $pod.automountServiceAccountToken == false and
    $pod.securityContext.seccompProfile.type == "RuntimeDefault" and
    any($pod.volumes[];
      .name == "k3s-db" and
      .hostPath.path == "/var/lib/rancher/k3s/server/db" and
      .hostPath.type == "Directory") and
    ($pod.containers[0] as $container |
      $container.securityContext.runAsUser == 0 and
      $container.securityContext.allowPrivilegeEscalation == false and
      $container.securityContext.readOnlyRootFilesystem == true and
      ($container.securityContext.privileged // false) == false and
      $container.securityContext.capabilities.drop == ["ALL"] and
      $container.securityContext.capabilities.add == ["DAC_OVERRIDE"] and
      any($container.volumeMounts[];
        .name == "k3s-db" and .mountPath == "/data/k3s-db" and .readOnly == true))
  ' "$rendered" >/dev/null \
    || die "Restic CronJobs must use the exact read-only k3s DB mount and minimally capable minis-only pod settings"
  if grep -Fq -- '/var/lib/rancher/k3s/server/token' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-cronjob.yaml" \
    "$REPO_ROOT/infrastructure/monitoring/restic-b2-cronjob.yaml"; then
    die "Restic CronJobs must never mount the k3s server token"
  fi
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-b2-backup") |
    .spec.schedule == "30 4 * * 0" and
    .spec.timeZone == "America/Chicago" and
    .spec.suspend == false and
    .spec.concurrencyPolicy == "Forbid" and
    .spec.jobTemplate.spec.backoffLimit == 0 and
    .spec.jobTemplate.spec.activeDeadlineSeconds == 21600 and
    ([.spec.jobTemplate.spec.template.spec.volumes[] | select(has("hostPath")) | .hostPath.path] | index("/mnt/backups") | not)' "$rendered" >/dev/null \
    || die "B2 CronJob schedule, safety settings, or volume independence is incorrect"
  yq -e 'select(.kind == "CronJob" and .metadata.name == "restic-b2-backup") |
    (.spec.jobTemplate.spec.template.spec.containers[0].env |
      from_entries |
      .RESTIC_TARGET_TAG == "b2" and
      .RESTIC_KEEP_DAILY == "" and
      .RESTIC_KEEP_WEEKLY == "8" and
      .RESTIC_KEEP_MONTHLY == "12")' "$rendered" >/dev/null \
    || die "B2 target tag or weekly/monthly retention policy is incorrect"
  grep -Fq -- "--tag \"\$target_tag\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not apply the selected target tag"
  grep -Fq -- "\"\${retention_args[@]}\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not build retention arguments dynamically"
  if grep -Fq -- "-newer \"\$HA_MARKER\"" "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml"; then
    die "shared Restic backup script still uses timestamp-based Home Assistant artifact detection"
  fi
  grep -Fq -- "home_assistant_new_backup_files \"\$HA_BACKUPS_BEFORE\" \"\$HA_BACKUPS_AFTER\"" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not compare Home Assistant backup filename sets"
  grep -Fq -- "-name '*.sqlite3'" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not discover .sqlite3 databases"
  grep -Fq -- 'required SQLite hot backup failed validation' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not fail when a required SQLite export is invalid"
  grep -Fq -- "assert_fresh_file \"\$out\" \"required SQLite hot backup\"" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not enforce required SQLite export freshness"
  grep -Fq -- 'mariadb-check' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not check RomM before its logical dump"
  grep -Fq -- "tar -tf \"\$backup\"" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not validate the new Home Assistant archive"
  grep -Fq -- 'write_backup_contract' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not write the recovery contract"
  grep -Fq -- "local source=/data/k3s-db/state.db" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not require the live k3s SQLite source"
  [ "$(grep -Fc -- "'.timeout 60000'" \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml")" -eq 2 ] \
    || die "shared Restic backup script must use a 60-second busy timeout for app and k3s SQLite backups"
  # shellcheck disable=SC2016 # Match literal variables in the embedded backup script.
  grep -Fq -- 'mv -- "$tmp" "$output"' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not publish the validated k3s artifact atomically"
  # shellcheck disable=SC2016 # Match a literal variable in the embedded backup script.
  grep -Fq -- 'validate_k3s_backup "$tmp"' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "shared Restic backup script does not validate k3s before atomic publication"
  yq -er '.data["backup.sh"]' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    | tail -n 7 \
    | grep -Fq $'dump_sqlite\ndump_k3s\ntrigger_home_assistant_backup\ndump_romm\nwrite_backup_contract\nrun_restic' \
    || die "shared Restic backup script does not make k3s export failure fatal before Restic"
  for restore_script in \
    runbooks/phase5/05-validate-restore.sh \
    runbooks/phase5/09-validate-b2-restore.sh; do
    grep -Fq -- 'REQUIRED_SQLITE_DATABASES' "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not validate the required SQLite inventory"
    grep -Fq -- 'mariadb-check' "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not import and validate the RomM dump"
    grep -Fq -- '/work/hot-dumps/k3s/state.db.sqlite-backup' "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not independently extract the k3s SQLite artifact"
    grep -Fq -- 'PRAGMA integrity_check;' "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not validate SQLite integrity"
    grep -Fq -- "name IN ('kine','sqlite_sequence')" "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not validate the k3s SQLite schema"
    grep -Fq -- 'SELECT count(*) FROM kine;' "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not require k3s datastore rows"
    grep -Fq -- 'snapshot contains a forbidden server-token artifact' \
      "$REPO_ROOT/$restore_script" \
      || die "$restore_script does not reject a k3s server-token artifact"
  done
  grep -Fq -- '/work/hot-dumps/k3s/state.db.sqlite-backup' \
    "$REPO_ROOT/runbooks/disaster-recovery/01-list-snapshots.sh" \
    || die "full-recovery selection does not require the contract-v2 k3s artifact"
  grep -Fq -- '-path /data/opt/.snapshots -prune -o' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "SQLite discovery does not prune the local btrfs snapshot tree"
  grep -Fq -- '--exclude /data/opt/.snapshots' \
    "$REPO_ROOT/infrastructure/monitoring/restic-nas-config.yaml" \
    || die "Restic backup does not exclude the local btrfs snapshot tree"
  ok "local and B2 backup invariants are intact"
}

assert_phase5_kustomize_builds() {
  local target
  for target in \
    infrastructure/monitoring \
    apps \
    clusters/minis; do
    kustomize build "$REPO_ROOT/$target" >/dev/null
    ok "kustomize build $target"
  done
}

assert_phase5_restic_secret_present() {
  [ -f "$PHASE5_RESTIC_SECRET" ] \
    || die "missing $PHASE5_RESTIC_SECRET; run runbooks/phase5/02-encrypt-restic-secret.sh"
  grep -q '^sops:' "$PHASE5_RESTIC_SECRET" \
    || die "$PHASE5_RESTIC_SECRET is not SOPS-encrypted"
  grep -q 'restic-nas.sops.yaml' "$PHASE5_MONITORING_DIR/kustomization.yaml" \
    || die "$PHASE5_RESTIC_SECRET is not included in infrastructure/monitoring/kustomization.yaml"
  ok "local Restic Secret manifest is SOPS-encrypted and included (legacy restic-nas name)"
}

assert_phase5_restic_b2_secret_present() {
  [ -f "$PHASE5_RESTIC_B2_SECRET" ] \
    || die "missing $PHASE5_RESTIC_B2_SECRET; run runbooks/phase5/06-encrypt-restic-b2-secret.sh"
  grep -q '^sops:' "$PHASE5_RESTIC_B2_SECRET" \
    || die "$PHASE5_RESTIC_B2_SECRET is not SOPS-encrypted"
  grep -q 'restic-b2.sops.yaml' "$PHASE5_MONITORING_DIR/kustomization.yaml" \
    || die "$PHASE5_RESTIC_B2_SECRET is not included in infrastructure/monitoring/kustomization.yaml"
  ok "Restic B2 Secret manifest is SOPS-encrypted and included"
}

wait_for_job() {
  local namespace="$1" job="$2" timeout="${3:-3600s}"
  local timeout_seconds deadline complete failed

  timeout_seconds="${timeout%s}"
  [ "$timeout_seconds" != "$timeout" ] || die "wait_for_job timeout must be in seconds, got: $timeout"
  deadline=$((SECONDS + timeout_seconds))

  while [ "$SECONDS" -lt "$deadline" ]; do
    complete="$(kubectl -n "$namespace" get "job/$job" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(kubectl -n "$namespace" get "job/$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [ "$complete" = "True" ]; then
      ok "job/$job completed"
      kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=120
      return 0
    fi
    if [ "$failed" = "True" ]; then
      warn "job/$job failed; recent logs follow"
      kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=200 || true
      kubectl -n "$namespace" describe "job/$job" || true
      return 1
    fi
    sleep 5
  done

  warn "job/$job did not complete before $timeout; recent logs follow"
  kubectl -n "$namespace" logs "job/$job" --all-containers=true --tail=200 || true
  kubectl -n "$namespace" describe pod -l "job-name=$job" || true
  kubectl -n "$namespace" describe "job/$job" || true
  return 1
}
