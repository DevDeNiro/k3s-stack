# Local Kubernetes Stack with K3d

Production-like Kubernetes environment using [k3d](https://k3d.io/) + [K3s](https://k3s.io/) for local development.

**One script setup. Clean URLs. No port-forwarding needed.**

---

## What You Get

| Service        | Purpose                        | URL                             |
|----------------|--------------------------------|---------------------------------|
| **Keycloak**   | Identity & Access Management   | `http://keycloak.local:30080`   |
| **Grafana**    | Monitoring Dashboards          | `http://grafana.local:30080`    |
| **Prometheus** | Metrics Collection             | `http://prometheus.local:30080` |
| **Vault**      | Secrets Management             | `http://vault.local:30080`      |
| **MinIO**      | Object Storage (S3-compatible) | `http://minio.local:30080`      |
| **Kafka + UI** | Message Streaming & Management | `http://kafka-ui.local:30080`   |
| **Dashboard**  | Cluster Management             | `https://localhost:8443`        |

> **ℹ️ Dashboard Access Note**  
> The Kubernetes Dashboard runs on `https://localhost:8443` via port-forwarding instead of Ingress. This approach
> provides better security and token validation for local development. Use `./dashboard.sh` to manage port-forwarding
> easily (start, stop, open browser, get token).

---

## Prerequisites

- **Docker Desktop** (running)
- **k3d** ≥ v5.0 – [Install](https://k3d.io/#installation)
- **kubectl** – [Install](https://kubernetes.io/docs/tasks/tools/)

---

## CI Lint Job

A CI lint job is configured in `.gitlab-ci.yml` to validate Helm charts before deployment:

- **Run Locally**:
  ```bash
  make helm-test      # Full lint + template validation
  make helm-lint      # Just lint the charts
  make helm-template  # Validate template generation
  ```

## Quick Start

```bash
# 1. Install everything
./install.sh

# 2. Setup clean URLs  
./deploy-ingress.sh
```

```
# Use the following command to Stop & Start the cluster :

k3d cluster stop dev-cluster
k3d cluster start dev-cluster
```

---

### ℹ️ Database Access - PostgreSQL & Redis

**PostgreSQL Access:**

- **CLI**: `kubectl exec -it postgresql-0 -n storage -- psql -U postgres`
- **Connection from Localhost **: `kubectl port-forward -n storage svc/postgresql 5432:5432`
- **From cluster**: `postgresql://myapp:PASSWORD@postgresql.storage.svc.cluster.local:5432/myapp`

**Redis Access:**

- **CLI**: `kubectl exec -it redis-master-0 -n storage -- redis-cli`
- **Connection URL**: `redis://:$(cat redis_password.txt)@localhost:30379`
- **From cluster**: `redis://:PASSWORD@redis-master.storage.svc.cluster.local:6379`

> Services exposed on NodePort - PostgreSQL: 30432, Redis: 30379
---

### Essential Commands

```bash
# Check everything is running
kubectl get pods -A

# View all services
kubectl get ingress -A


# Dashboard management
./dashboard.sh start    # Start Dashboard port-forward
./dashboard.sh open     # Open Dashboard in browser
./dashboard.sh token    # Get access token
./dashboard.sh status   # Check Dashboard status

# Cleanup
./uninstall.sh

# Monitor resources usage 
kubectl top nodes
kubectl describe nodes
```

---

### Development Workflow

1. **Start:** `./install.sh` → Select services to install
2. **Access:** `./deploy-ingress.sh` → Get clean URLs
3. **Develop:** Use supporting services (auth, monitoring, storage)
4. **Deploy:** Add your apps to the cluster
5. **Cleanup:** `./uninstall.sh`

---

### Quick Fixes

**Ingress not working?**

```bash
kubectl get svc -n ingress-nginx
grep "local" /etc/hosts
```

**Service down?**

```bash
kubectl logs -n <namespace> <pod-name>
kubectl describe pod <pod-name> -n <namespace>
```

1. Namespaces and Argo CD:
   • You've defined namespaces under argocd, storage, messaging, security, monitoring, and vault.
   • There's a default argocd project in local-k3d.yaml for application management.
2. GitLab CI Configuration:
   • The GitLab CI script creates directories for each branch slug and sets up Helm values making use of the branch name
   dynamically.
3. Ingress and ServiceAccount Management:
   • Ingress configurations for services seem to follow the discussed pattern.
   • There is some mention of creating service accounts and RBAC under the argo-cd values file.
