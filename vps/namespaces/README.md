# Namespaces

This directory holds the **infrastructure namespaces**, applied by `vps/install.sh`.

| Namespace | File | Pod Security (enforce) | Why |
|-----------|------|------------------------|-----|
| `storage` | `infrastructure.yaml` | baseline | PostgreSQL, backups |
| `security` | `infrastructure.yaml` | baseline | Keycloak |
| `monitoring` | `infrastructure.yaml` | privileged | node-exporter (hostNetwork, hostPID) and Promtail (hostPath) |
| `database` | `database.yaml` | baseline | Redis |
| `argocd` | `gitops.yaml` | baseline | Argo CD, Image Updater |
| `cert-manager` | `cert-manager.yaml` | baseline | cert-manager |
| `nginx-gateway` | `nginx-gateway.yaml` | privileged | NGINX data plane on hostPorts 80/443 |

Privileged namespaces keep `audit` and `warn` at `baseline`: what exceeds baseline is still
reported.

## Application namespaces

Created by `vps/scripts/onboard-app.sh <app>` from
`vps/templates/onboarding/namespace.yaml.tpl`: `<app>-alpha` and `<app>-prod`, with a
ResourceQuota, default container limits and the Pod Security level of
`vps/config/onboarding/<env>.env` (alpha `baseline`, prod `restricted`). Their label
`app.kubernetes.io/managed-by=k3s-stack` grants access to PostgreSQL, Redis and Keycloak
(`vps/manifests/network-policies.yaml`) and lets `uninstall.sh` find them.
