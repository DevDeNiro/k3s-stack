# K3s Stack

Kubernetes platform for a **single VPS**, with a **local k3d mirror** for development.

## Overview

- **K3s** v1.37 single node, secrets encrypted at rest, audit log, firewall with the API closed
- **NGINX Gateway Fabric** (Gateway API) with Let's Encrypt certificates (cert-manager)
- **PostgreSQL** 18 with TLS and SCRAM, one role and database per application, daily/weekly/monthly backups
- **Keycloak** 26: only the OIDC endpoints are public, the master realm and the admin console are not
- **Redis**, **Argo CD** with repository auto-discovery and Image Updater, **Sealed Secrets**
- **Prometheus, Alertmanager (Discord), Loki, Promtail, Grafana**

Configuration lives in files (`vps/config`, `vps/templates`, `vps/values`), the scripts hold
the logic, versions are pinned in [`vps/config/versions.env`](vps/config/versions.env), and a
full reinstallation is the nominal way to apply a major change.

## Deployment modes

| Mode | Use case | Documentation |
|------|----------|---------------|
| **VPS** | production on a 4-6 GB server | [`vps/README.md`](vps/README.md) (every script and parameter) |
| **Local** | development with k3d + Docker | [`local/README.md`](local/README.md) |

Security model and migration of an existing VPS:
[`vps/docs/security-hardening.md`](vps/docs/security-hardening.md).

## Quick start

### VPS

```bash
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
cp vps/config.env.example vps/config.env && nano vps/config.env
sudo ./vps/install.sh
```

Then follow [`vps/docs/vps-deployment.md`](vps/docs/vps-deployment.md).

### Local

```bash
./local/install.sh --all
./local/deploy-app.sh
```

## Project structure

```text
k3s-stack/
├── vps/        # VPS installation: scripts, configuration, templates, Helm values, docs
├── local/      # k3d mirror: scripts and local differences
└── charts/     # common-library, shared Helm chart of the applications (published to GHCR)
```

## Checks

```bash
make lint           # ShellCheck on every script
make helm-test      # Helm lint and template validation
```

## Cleanup

```bash
sudo ./vps/uninstall.sh          # platform only, K3s kept
sudo ./vps/uninstall.sh --all    # K3s and Helm too (full reinstallation)
./local/uninstall.sh             # local cluster
```

## License

Apache-2.0
