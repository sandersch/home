# Infrastructure

GitOps-managed cluster platform resources live here. Phase 3 infrastructure and the
live-validated Phase 5 backup/observability slice are implemented as Flux-managed
manifests.

Flux applies these before apps through ordered Kustomizations in `clusters/minis/`:

- `controllers/` installs platform controllers with HelmRepository and HelmRelease.
- `configs/` applies cluster-wide config and CRD-backed resources after controllers
  are ready.
- `monitoring/` contains Phase 5 backup resources plus the deployed Prometheus,
  Grafana, Alertmanager, blackbox probing, Flux metrics, rules, and external Watchdog
  routing stack.

Do not add plaintext credentials. Infrastructure secrets must be SOPS-encrypted before
commit.
