# K3s Stack

Production-ready Kubernetes infrastructure for deploying applications on a **single VPS** or **locally** for
development.

## Overview

A lightweight K3s stack with everything you need to run containerized applications:

- **PostgreSQL** — Database with automated backups
- **Keycloak** — Identity management (SSO/OAuth2/OIDC)
- **Prometheus + Grafana** — Monitoring and dashboards
- **NGINX Ingress** — HTTP/HTTPS routing with Let's Encrypt
- **Argo CD** — GitOps continuous deployment
- **Sealed Secrets** — Secure secret management

## Deployment Modes

| Mode      | Use Case                                | Documentation                        |
|-----------|-----------------------------------------|--------------------------------------|
| **VPS**   | Production on remote server (4-6GB RAM) | [`vps/README.md`](vps/README.md)     |
| **Local** | Development with k3d + Docker           | [`local/README.md`](local/README.md) |

## Quick Start

### VPS (Production)

```bash
ssh root@<VPS-IP>
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
./vps/install.sh
```

→ See [`vps/docs/vps-deployment.md`](vps/docs/vps-deployment.md) for the complete guide.

### Local (Development)

```bash
./local/install.sh
./local/deploy-ingress.sh
```

→ See [`local/README.md`](local/README.md) for details.

## Project Structure

```
k3s-stack/
├── vps/           # Scripts and configs for VPS deployment
├── local/         # Scripts and configs for local k3d
├── charts/        # Shared Helm charts
└── docs/          # Detailed documentation
```

## Helm Lint (CI)

```bash
make helm-test      # Lint + template validation
make helm-lint      # Lint only
make helm-template  # Template validation only
```

## Cleanup

```bash
# VPS - partial (keeps K3s + Helm)
./vps/uninstall.sh

# VPS - full removal
./vps/uninstall.sh --all

# Local
./local/uninstall.sh
```

## License

Apache-2.0 license
