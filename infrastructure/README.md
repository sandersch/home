# Infrastructure

GitOps-managed cluster platform resources live here. Phase 3 infrastructure is
implemented as Flux-managed manifests; Phase 5 starts with backup resources under
`monitoring/`.

Flux applies these before apps through ordered Kustomizations in `clusters/minis/`:

- `controllers/` installs platform controllers with HelmRepository and HelmRelease.
- `configs/` applies cluster-wide config and CRD-backed resources after controllers
  are ready.
- `monitoring/` applies Phase 5 backup resources now and will also hold observability.

Do not add plaintext credentials. Infrastructure secrets must be SOPS-encrypted before
commit.
