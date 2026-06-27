# Infrastructure Configs

Cluster-wide config and CRD-backed resources live here after their controllers are
installed by `../controllers`.

Managed resources include MetalLB pools, the cert-manager ClusterIssuer,
PriorityClasses, StorageClasses, and SOPS-encrypted operational Secrets generated
by the Phase 3 runbook.
