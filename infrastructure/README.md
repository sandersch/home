# Infrastructure

GitOps-managed cluster platform resources live here. Phase 3 infrastructure is
implemented as Flux-managed manifests; Phase 5 monitoring is still reserved.

Flux applies these before apps through ordered Kustomizations in `clusters/minis/`:

- `controllers/` installs platform controllers with HelmRepository and HelmRelease.
- `configs/` applies cluster-wide config and CRD-backed resources after controllers
  are ready.
- `monitoring/` is reserved for observability resources in Phase 5.

Do not add plaintext credentials. Infrastructure secrets must be SOPS-encrypted before
commit.
