# K3s Stack

Infrastructure Kubernetes légère pour déployer des applications sur **VPS** ou en **local**.

## Vue d'ensemble

Ce projet fournit une stack K3s prête à l'emploi avec :

- **PostgreSQL** — Base de données avec backups automatiques
- **Keycloak** — Gestion d'identité (SSO/OAuth2)
- **Prometheus + Grafana** — Monitoring et dashboards
- **Ingress NGINX** — Routage HTTP/HTTPS
- **Argo CD** — GitOps pour déploiement continu
- **Sealed Secrets** — Gestion sécurisée des secrets

## Modes de déploiement

| Mode      | Usage                                      | Documentation                        |
|-----------|--------------------------------------------|--------------------------------------|
| **VPS**   | Production sur serveur distant (4-6GB RAM) | [`vps/README.md`](vps/README.md)     |
| **Local** | Développement avec k3d + Docker            | [`local/README.md`](local/README.md) |

## Quick Start

### VPS (Production)

```bash
ssh root@<VPS-IP>
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
./vps/install.sh
```

→ Voir [`vps/docs/vps-deployment.md`](vps/docs/vps-deployment.md) pour le guide complet.

### Local (Développement)

```bash
./local/install.sh
./local/deploy-ingress.sh
```

→ Voir [`local/README.md`](local/README.md) pour les détails.

## Structure

```
k3s-stack/
├── vps/           # Scripts et configs pour déploiement VPS
├── local/         # Scripts et configs pour k3d local
├── charts/        # Helm charts partagés
└── docs/          # Documentation détaillée
```

## Helm Lint (CI)

```bash
make helm-test      # Lint + template validation
make helm-lint      # Lint only
make helm-template  # Template validation only
```

## Cleanup

```bash
# VPS - partiel (garde K3s + Helm)
./vps/uninstall.sh

# VPS - total
./vps/uninstall.sh --all

# Local
./local/uninstall.sh
```

## TODO

- [ ] Externaliser les migrations via Job Kubernetes séparé
