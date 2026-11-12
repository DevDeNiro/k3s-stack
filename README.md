# K3s Stack

Kubernetes platform for a **single VPS**, with a **local k3d mirror** for development.

## Overview

- **K3s** v1.37 single node, secrets encrypted at rest, audit log, firewall with the API closed
- **NGINX Gateway Fabric** (Gateway API) with Let's Encrypt certificates (cert-manager), access
  logs without query strings
- **PostgreSQL** 18 with TLS and SCRAM, one role and database per application, daily/weekly/monthly
  backups and an optional encrypted off-site copy (restic, S3-compatible storage)
- **Keycloak** 26: only the OIDC endpoints are public (rate limited per client address), the master
  realm and the admin console are not; themes and providers come from extension images
- **Argo CD** with repository auto-discovery across several GitHub organizations, one project per
  application, and Image Updater, **Sealed Secrets**
- **Applications isolated from each other**: each one gets its namespaces (Pod Security
  `restricted`, quota, default NetworkPolicy), its database role, its Argo CD project and its
  public hostnames; caches such as Redis live in the application chart
- **Prometheus, Alertmanager (Discord), Loki, Alloy, Grafana**, with secrets carried by URLs
  masked before Loki

Configuration lives in files (`vps/config`, `vps/templates`, `vps/values`), the scripts hold
the logic, and versions are pinned in [`vps/config/versions.env`](vps/config/versions.env).
New installations use the pinned defaults. An existing cluster requires a tested,
component-specific upgrade or migration plan; reinstalling deletes local data and backups.

## Deployment modes

| Mode | Use case | Documentation |
|------|----------|---------------|
| **VPS** | production on a 4-6 GB server | [`vps/README.md`](vps/README.md) (every script and parameter) |
| **Local** | development with k3d + Docker | [`local/README.md`](local/README.md) |

Security model and known limitations:
[`vps/docs/security-hardening.md`](vps/docs/security-hardening.md).

## Quick start

### VPS

Follow [`vps/docs/installation-onboarding.md`](vps/docs/installation-onboarding.md).

### Local

```bash
./local/install.sh --all
./local/deploy-app.sh <app>     # chart ../<app>/helm/<app>, values-local.yaml
```

## Example applications

- **React** (Vite build served by nginx, no database):
  [DevDeNiro/react-starter-kit](https://github.com/DevDeNiro/react-starter-kit)

Repository layout expected by the Argo CD auto-discovery:
[`vps/docs/deployment-flow.md`](vps/docs/deployment-flow.md#example-applications).

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
make helm-test      # Helm lint and template validation for repository charts
make helm-external-test  # render and check VPS/local external charts (Helm, Ruby, network)
make alloy-test     # offline Alloy pipeline/positions test (Python 3, Docker, cached image)
```

External chart checks use an isolated temporary Helm configuration and never contact a
cluster. They validate rendered resources, not live upgrades or runtime compatibility.
`alloy-test` needs the cached official image `grafana/alloy:v1.21.3` and uses only
synthetic logs in an isolated container.

## Cleanup

```bash
sudo ./vps/uninstall.sh          # platform only, K3s kept
sudo ./vps/uninstall.sh --all    # K3s and Helm too (full reinstallation)
./local/uninstall.sh             # local cluster
```

## License

Apache-2.0
