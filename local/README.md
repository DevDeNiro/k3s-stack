# Local Kubernetes Stack (VPS Mirror on K3d)

A production-parity Kubernetes environment using [k3d](https://k3d.io/) + [K3s](https://k3s.io/) mirroring the VPS architecture.

**Identical routing (Gateway API), GitOps (Argo CD), storage, and secret controllers. What works locally works on the VPS.**

---

## Architecture Parity Matrix

| Component | Local (k3d) | VPS (k3s) | Notes |
|-----------|-------------|-----------|-------|
| **K3s Version** | `v1.29.0+k3s1` | `v1.29.0+k3s1` | Pinned exact match |
| **Traffic Ingress** | Gateway API v1.2.0 + NGINX Gateway Fabric 2.4.1 | Gateway API v1.2.0 + NGINX Gateway Fabric 2.4.1 | `infrastructure-gateway` in `nginx-gateway` namespace |
| **GitOps** | Argo CD v2.14+ in `argocd` | Argo CD in `argocd` | Dynamic App deployment & sync |
| **Database** | PostgreSQL in `storage` | PostgreSQL in `storage` | Service: `postgresql.storage.svc.cluster.local:5432` |
| **Cache/Sessions**| Redis in `database` | Redis in `database` | Service: `redis.database.svc.cluster.local:6379` |
| **Secrets Engine** | Sealed Secrets in `kube-system` | Sealed Secrets in `kube-system` | Public key exported to `local/secrets/` |
| **IAM** (Optional) | Keycloak in `security` | Keycloak in `security` | Service: `keycloak.security.svc.cluster.local:8080` |

---

## Prerequisites

- **Docker Desktop** (running)
- **k3d** (v5.8+) : `scoop install k3d` or `winget install Rancher.k3d`
- **helm** (v3.14+) : `scoop install helm` or `winget install Helm.Helm`
- **kubectl** : bundled with Docker Desktop or `winget install Kubernetes.kubectl`

---

## Quick Start

### 1. Install / Launch the Mirror Stack
```bash
# Minimal stack (Gateway API, Argo CD, Postgres, Redis, Sealed Secrets) - recommended
./local/install.sh --minimal

# Full stack (including Keycloak and Prometheus/Grafana)
./local/install.sh --all

# Or with Makefile
make local-install
```

### 2. Deploy Reference Applications
```bash
# Deploys:
# - react-starter-kit (Frontend) -> http://react-starter-kit.local
# - coterie-webapp (Backend)    -> http://coterie.local
./local/deploy-app.sh --all

# Or via Makefile
make local-deploy-apps
```

### 3. Configure Local Hostnames
Add the following line to `C:\Windows\System32\drivers\etc\hosts` (or `/etc/hosts` on Linux/macOS):
```text
127.0.0.1  coterie.local react-starter-kit.local
```

Test immediately:
```bash
curl -i -H "Host: coterie.local" http://localhost/
curl -i -H "Host: react-starter-kit.local" http://localhost/
```

---

## Multi-Cluster Context Switching

Your local `~/.kube/config` seamlessly hosts both clusters:
```bash
# Switch to Local k3d cluster
kubectl config use-context k3d-dev-cluster

# Switch back to VPS
kubectl config use-context default
```

---

## Accessing Services & UIs

- **Argo CD UI**:
  ```bash
  kubectl port-forward -n argocd svc/argocd-server 8443:80
  # Open http://localhost:8443
  # Username: admin
  # Password in: local/argocd_password.txt
  ```

- **PostgreSQL CLI**:
  ```bash
  kubectl exec -it -n storage postgresql-0 -- psql -U postgres
  ```

- **Redis CLI**:
  ```bash
  kubectl exec -it -n database deploy/redis -- redis-cli
  ```

---

## Cleanup / Teardown
```bash
./local/uninstall.sh
# or
k3d cluster delete dev-cluster
```
