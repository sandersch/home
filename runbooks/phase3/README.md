# Phase 3 - GitOps-managed cluster infrastructure

Scripts for [build-plan.md Phase 3](../../docs/build-plan.md#phase-3--gitops-managed-cluster-infrastructure-).
Run them on `minis` after Phase 2 bootstrap has reconciled.

## Prerequisites

- Phase 0-2 are complete.
- `kubectl`, `flux`, `kustomize`, and `sops` are installed on `minis`.
- The repo has `.sops.yaml` from Phase 2 and the matching `flux-system/sops-age`
  Secret exists in-cluster.
- You have the CloudDNS service-account JSON for project `kubetest-333602`.
- You have Tailscale OAuth client credentials whose tags allow the Kubernetes
  operator tags configured in the manifests.

## Order

| Script | What it does |
|---|---|
| `00-preflight.sh` | Validates local kustomize output and checks encrypted secret manifests exist |
| `01-encrypt-secrets.sh` | Creates SOPS-encrypted CloudDNS and Tailscale Secret manifests |
| `02-reconcile.sh` | Reconciles `infra-controllers`, `infra-configs`, then `apps` |
| `03-validation-gate.sh` | Runs the automated Phase 3 validation gate |

## Secret generation

```bash
export CLOUDDNS_SERVICE_ACCOUNT_JSON=/path/to/clouddns-key.json
export TAILSCALE_OAUTH_CLIENT_ID=...
export TAILSCALE_OAUTH_CLIENT_SECRET=...
./runbooks/phase3/01-encrypt-secrets.sh
```

Review the generated `*.sops.yaml` files before commit. They must contain SOPS
metadata and encrypted `data` fields, never plaintext key material.
