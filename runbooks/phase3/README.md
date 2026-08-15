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
- On a rebuild, both the `apps` and `monitoring` Flux Kustomizations are suspended in
  committed git state. Keep them suspended until `/opt` is restored and validated.

## Order

| Script | What it does |
|---|---|
| `00-preflight.sh` | Validates local kustomize output and checks encrypted secret manifests exist |
| `01-encrypt-secrets.sh` | Creates SOPS-encrypted CloudDNS and Tailscale Secret manifests |
| `02-reconcile.sh` | Reconciles `infra-controllers` and `infra-configs`; reconciles `apps` only on the active/live path, or verifies both rebuild guards remain suspended |
| `03-validation-gate.sh` | Runs the automated Phase 3 infrastructure gate and accepts suspended apps only when the backup slice is suspended too |

## Secret generation

```bash
export CLOUDDNS_SERVICE_ACCOUNT_JSON=/path/to/clouddns-key.json
export TAILSCALE_OAUTH_CLIENT_ID=...
export TAILSCALE_OAUTH_CLIENT_SECRET=...
./runbooks/phase3/01-encrypt-secrets.sh
```

Review the generated `*.sops.yaml` files before commit. They must contain SOPS
metadata and encrypted `data` fields, never plaintext key material. The CloudDNS
Secret belongs to `infrastructure/configs/secrets`; the Tailscale OAuth Secret
belongs to `infrastructure/controllers/tailscale` so the Helm chart can mount it
during the controller phase.

For a rebuild, proceed from the validation gate to the
[full `/opt` restore](../../docs/build-plan.md#fresh-rebuild-and-disaster-recovery).
Do not use `flux resume` directly: remove the apps guard in git after restore, validate
the workloads, and remove the monitoring backup guard in a second commit.

## Tailnet remote access

`infrastructure/configs/tailscale` advertises only the ingress IP
`10.137.20.10/32` and router DNS IP `10.137.20.1/32` through the Tailscale
operator Connector. In the Tailscale admin console, approve those routes for the
`tag:k8s` Connector device and configure split DNS for `worm.run` to use
`10.137.20.1`. Do not advertise the full `10.137.20.0/24` LAN.
