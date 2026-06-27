# Infrastructure Controllers

HelmRepository and HelmRelease manifests for platform controllers live here.

Managed controllers:

- MetalLB
- ingress-nginx
- cert-manager
- Tailscale operator
- TopoLVM

These are reconciled by the `infra-controllers` Flux Kustomization before
CRD-backed config in `../configs`.
