#!/usr/bin/env bash
# Phase 3 validation gate - confirm platform readiness before Phase 3.5/4.
# shellcheck source=runbooks/phase3/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_not_root
require_tools kubectl
require_flux_cli

step "Kubernetes and Flux readiness"
kubectl get nodes
kubectl get node minis -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  | grep -qx True || die "node minis is not Ready"
ok "node minis is Ready"
flux get kustomizations
kustomization_ready flux-system 180s
kustomization_ready infra-controllers 300s
kustomization_ready intel-gpu-plugin 300s
kustomization_ready infra-configs 300s
if kustomization_is_suspended apps; then
  require_kustomization_suspended apps
  require_kustomization_suspended monitoring
  ok "rebuild guard is intact; restore app state before resuming apps"
else
  kustomization_ready apps 180s
fi
flux get helmreleases -A

step "Controller CRDs"
kubectl get crd ipaddresspools.metallb.io l2advertisements.metallb.io >/dev/null
kubectl get crd clusterissuers.cert-manager.io certificates.cert-manager.io >/dev/null
kubectl get crd dnsconfigs.tailscale.com proxyclasses.tailscale.com >/dev/null
kubectl get crd logicalvolumes.topolvm.io >/dev/null
ok "MetalLB, cert-manager, Tailscale, and TopoLVM CRDs exist"

step "Ingress and certificate plumbing"
kubectl -n ingress-nginx get pods
kubectl -n cert-manager get pods
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -qx 10.137.20.10 \
  || die "ingress-nginx LoadBalancer IP is not 10.137.20.10"
kubectl wait clusterissuer/letsencrypt-dns01 --for=condition=Ready --timeout=300s
ok "ingress LoadBalancer and ClusterIssuer are ready"

step "Storage classes"
kubectl get storageclass local-nvme local-path topolvm-scratch
ok "storage classes exist"

step "Direct-attached media filesystem readable from a test pod"
assert_direct_mount_layout /mnt/media /dev/mapper/hoardvg-medialv \
  0a94d86c-76a0-44b5-bc52-930d97ab155f
# renovate: datasource=docker depName=busybox
kubectl run phase3-media-test --restart=Never --rm -i --image=busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
  --overrides='{"spec":{"volumes":[{"name":"media","hostPath":{"path":"/mnt/media","type":"Directory"}}],"containers":[{"name":"phase3-media-test","image":"busybox:1.36","command":["sh","-c","df -T -P /media | tail -n 1 | grep -Eq \"^/dev/mapper/hoardvg-medialv[[:space:]]+ext4[[:space:]]\" && ls -la /media >/dev/null"],"volumeMounts":[{"name":"media","mountPath":"/media"}]}]}}'
ok "direct-attached /mnt/media is readable from a test pod"

step "Device passthrough visibility"
kubectl get node minis -o jsonpath="{.status.allocatable['gpu.intel.com/i915']}" \
  | grep -qx '2' || die "node minis does not advertise gpu.intel.com/i915=2"
ok "Intel GPU plugin advertises gpu.intel.com/i915=2 on node minis"
# renovate: datasource=docker depName=busybox
kubectl run phase3-dri-test --restart=Never --rm -i --image=busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
  --overrides='{"spec":{"containers":[{"name":"phase3-dri-test","image":"busybox:1.36","command":["sh","-c","test -e /dev/dri/renderD128"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"dri","mountPath":"/dev/dri"}]}],"volumes":[{"name":"dri","hostPath":{"path":"/dev/dri","type":"Directory"}}]}}'
# renovate: datasource=docker depName=busybox
kubectl run phase3-coral-test --restart=Never --rm -i --image=busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
  --overrides='{"spec":{"containers":[{"name":"phase3-coral-test","image":"busybox:1.36","command":["sh","-c","ls /dev/bus/usb/*/* >/dev/null"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"usb","mountPath":"/dev/bus/usb"}]}],"volumes":[{"name":"usb","hostPath":{"path":"/dev/bus/usb","type":"Directory"}}]}}'
ok "Quick Sync and USB device paths are visible in privileged test pods"

step "Host services"
service_active nut-server
service_active nut-monitor
service_active dnsmasq
service_active chrony

cat <<'EOF'

Manual checks still required:
- From a camera-segment test device with gateway 192.168.105.1, confirm internet/LAN
  pings fail and cam-drop-fwd-* appears in journalctl -k.
- Confirm camera segment cannot reach host TCP :22 and :6443.
- Confirm two cameras on protected switch ports cannot reach each other.
- Confirm every real camera has a stable dnsmasq reservation and uses NTP 192.168.105.1.
- Confirm Tailscale has approved Connector routes 10.137.20.10/32 and 10.137.20.1/32.
- Confirm Tailscale split DNS for worm.run uses 10.137.20.1 and resolves *.worm.run to 10.137.20.10 over the Tailnet.
EOF

ok "automated Phase 3 validation complete"
