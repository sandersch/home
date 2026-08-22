# k3s Upgrade History

This log records attended host maintenance separately from the target pin. A target
being committed does not make it the validated live baseline; update the maintenance,
validation, observation, and cleanup fields only from evidence collected on `minis`.

| Source | Target | Target release date | Maintenance date | Validation | 24-hour observation | Rollback artifacts |
|---|---|---|---|---|---|---|
| `v1.36.2+k3s1` | `v1.36.3+k3s1` | 2026-08-04 | Pending | Not run; target pin and runbooks staged 2026-08-22 | Not started | Not created |

The target release updates Kubernetes to v1.36.3. Its Traefik v40 migration warning
does not affect this cluster because bundled Traefik is disabled and ingress-nginx is
the ingress controller. Source: [official k3s v1.36.3+k3s1 release](https://github.com/k3s-io/k3s/releases/tag/v1.36.3%2Bk3s1).

For each maintenance, record the UTC start/end, reviewed git commit, checkpoint and
snapshot paths, all acceptance-gate results, any new warning events/restarts, rollback
decision, observation close time, and artifact cleanup. Keep tokens and checkpoint
contents out of git.
