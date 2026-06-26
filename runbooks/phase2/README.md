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
- The `flux` CLI is installed and authenticated as needed for `flux bootstrap github`.
- GitHub owner/repository/branch are `sandersch/home` on `main`, matching the build
  plan.

## Order

Run scripts in numeric order, or run `./run-all.sh` for steps 00-04. Run validation
after bootstrap has settled.

| Script | Build-plan step | What it does | Interactive? |
|---|---|---|---|
| `00-preflight.sh` | - | Read-only sanity checks for host, repo, and tool posture | no |
| `01-install-k3s.sh` | 2.1 | Installs k3s with Traefik and servicelb disabled, node name `minis`; copies kubeconfig to the runbook user's `~/.kube/config` as `0600` | install prompt |
| `02-age-keypair.sh` | 2.2 | Creates or reuses `age.key`, prints public key, requires backup confirmation | backup prompt |
| `03-sops-age-secret.sh` | 2.3 | Creates or validates `flux-system/sops-age` from `age.key` | no |
| `04-sops-config.sh` | 2.4 | Writes `.sops.yaml` using the generated public key | overwrite prompt if needed |
| `05-flux-bootstrap.sh` | 2.5 | Runs `flux bootstrap github` for the private repo | bootstrap prompt |
| `06-validate-bootstrap.sh` | - | Validates node readiness, Flux manifests, SOPS secret, and Flux health | no |

## Notes

- `age.key` is intentionally local-only. Back it up to the password manager and do
  not commit it.
- `.sops.yaml` contains only the public age recipient and is committed normally.
- `run-all.sh` stops after `.sops.yaml` is written. Review, commit, and push the
  repo changes before running `05-flux-bootstrap.sh` manually.
- `05-flux-bootstrap.sh` requires the repo to be clean and up to date with its
  upstream. Commit and push `.sops.yaml` before running it; ignored `age.key` is
  allowed to remain local.
- `flux bootstrap` owns `clusters/minis/flux-system`; do not hand-edit that subtree.
- The existing Flux skeleton outside `flux-system` stays repo-owned and is reconciled
  after bootstrap.
- Phase 3 is the first normal Flux-managed cluster infrastructure phase. Do not use
  imperative Helm installs for MetalLB, ingress-nginx, cert-manager, Tailscale, or
  TopoLVM.
