# Phase 2 - k3s + Flux bootstrap prerequisites (runbook)

Scripts for [build-plan.md Phase 2](../../docs/build-plan.md#phase-2--k3s--flux-bootstrap-prerequisites-).
They run on `minis` after Phase 0 and Phase 1 host setup.

This phase is intentionally small. The only imperative cluster writes are the k3s
install, the `flux-system/sops-age` Secret, and `flux bootstrap`. Everything else
that changes Kubernetes state belongs in git and is reconciled by Flux in Phase 3.

## Prerequisites

- Phase 0 is complete, including hostname `minis`, swap disabled, base packages,
  and readable `/mnt/media`.
- Phase 1 host-side camera isolation is applied.
- This repo is checked out on `minis`.
- The `flux` CLI is installed on `minis`:
  ```bash
  curl -s https://fluxcd.io/install.sh | sudo bash
  flux version --client
  ```
  `flux bootstrap github` uses `GITHUB_TOKEN`; export it before running
  `05-flux-bootstrap.sh`.
- GitHub owner/repository/branch are `sandersch/home` on `main`, matching the build
  plan.
- For a rebuild of this populated repo, restore the existing `age.key` from the
  password manager. Do not generate a replacement key; it cannot decrypt the committed
  SOPS Secrets.
- Before `05-flux-bootstrap.sh`, add `spec.suspend: true` to both
  `clusters/minis/apps.yaml` and `clusters/minis/monitoring.yaml`, then commit and push
  that rebuild guard. Do this only after the old cluster is offline or after
  deliberately accepting paused Flux reconciliation there.

## Order

Run scripts in numeric order, or run `./run-all.sh` for steps 00-04. Run validation
after bootstrap has settled.

| Script | Build-plan step | What it does | Interactive? |
|---|---|---|---|
| `00-preflight.sh` | - | Read-only sanity checks for host, repo, and tool posture | no |
| `01-install-k3s.sh` | 2.1 | Installs the canonical k3s server config, installs exact release `v1.36.2+k3s1` with Traefik and servicelb disabled and node name `minis`, then copies kubeconfig to the runbook user's `~/.kube/config` as `0600`; an active server must already match the pin | install prompt; restart prompt when changing an active server |
| `02-age-keypair.sh` | 2.2 | Creates a key only for an initial build; on a rebuild, requires the restored `age.key` to match the committed SOPS recipient | backup prompt |
| `03-sops-age-secret.sh` | 2.3 | Creates or validates `flux-system/sops-age` from `age.key` | no |
| `04-sops-config.sh` | 2.4 | Writes `.sops.yaml` using the generated public key | overwrite prompt if needed |
| `05-flux-bootstrap.sh` | 2.5 | Verifies the committed apps/backup suspend guards, then runs `flux bootstrap github` for the private repo | bootstrap prompt |
| `06-validate-bootstrap.sh` | - | Validates node readiness, Flux manifests, SOPS secret, and Flux health | no |

## Notes

- `age.key` is intentionally local-only. Back it up to the password manager and do
  not commit it.
- `host/minis/etc/rancher/k3s/config.yaml` bounds cluster-wide terminal Pod objects
  at 20 via `terminated-pod-gc-threshold`. PodGC removes the oldest `Failed` or
  `Succeeded` Pods after the total exceeds that threshold, so their old logs are not
  retained indefinitely.
- `K3S_VERSION` in `lib.sh` is the canonical exact installer and validation pin.
  `01-install-k3s.sh` passes it to the upstream installer as
  `INSTALL_K3S_VERSION`; both the installer guard and `06-validate-bootstrap.sh`
  reject an active server on a different release. Updating this value is host
  maintenance and must follow the gate in `docs/version-management.md`.
- `.sops.yaml` contains only the public age recipient and is committed normally.
- `run-all.sh` stops after `.sops.yaml` is written. Review, commit, and push the
  repo changes and the two rebuild suspend guards before running
  `05-flux-bootstrap.sh` manually.
- `05-flux-bootstrap.sh` requires the repo to be clean and up to date with its
  upstream. Commit and push `.sops.yaml` before running it; ignored `age.key` is
  allowed to remain local.
- `flux bootstrap` owns `clusters/minis/flux-system`; do not hand-edit that subtree.
- The existing Flux skeleton outside `flux-system` stays repo-owned and is reconciled
  after bootstrap.
- A suspended Flux Kustomization prevents new reconciliation; it does not stop
  workloads that already exist. A fresh rebuild must show no app pods and no Restic
  CronJobs before `/opt` is restored.
- Phase 3 is the normal Flux-managed cluster infrastructure phase. Do not use
  imperative Helm installs for MetalLB, ingress-nginx, cert-manager, Tailscale, or
  TopoLVM.
