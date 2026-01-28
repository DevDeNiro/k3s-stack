# 🚀 K3s VPS Deployment

Deploy a production-ready K3s cluster on a VPS (4-6GB RAM) with essential services.

## 📋 What You Get

| Service           | Purpose                                          | Memory |
|-------------------|--------------------------------------------------|--------|
| **K3s**           | Kubernetes runtime                               | ~500MB |
| **PostgreSQL**    | Database with pg_stat_statements + WAL archiving | ~384MB |
| **Keycloak**      | Identity & Access Management                     | ~768MB |
| **Prometheus**    | Metrics collection                               | ~256MB |
| **Grafana**       | Monitoring dashboards                            | ~256MB |
| **Ingress NGINX** | HTTP(S) routing                                  | ~256MB |

**Total: ~2.5GB** (leaves ~1.5GB for your applications on a 4GB VPS)

## 🎯 Prerequisites

### VPS Requirements

- **OS**: Ubuntu 22.04 LTS or Debian 12
- **RAM**: 4GB minimum (6GB recommended)
- **Disk**: 40GB SSD minimum
- **Ports**: 22 (SSH), 80, 443, 6443 (K3s API)

### Local Machine

- `kubectl` installed
- SSH access to VPS with key-based authentication

## 🚀 Quick Start

### 1. On the VPS

```bash
# SSH into your VPS
ssh root@your-vps-ip

# Clone this repository
git clone https://github.com/your-org/k3d-stack.git
cd k3d-stack

# Run the installation script
chmod +x vps/install.sh
./vps/install.sh
```

The script will:

- Install K3s (lightweight Kubernetes)
- Install Helm
- Create infrastructure namespaces (storage, security, monitoring)
- Deploy PostgreSQL, Keycloak, Prometheus, Grafana, Ingress NGINX
- Setup PostgreSQL backup CronJob

### 2. On Your Local Machine

```bash
# Configure kubectl to connect to your VPS
chmod +x vps/scripts/setup-remote.sh
./vps/scripts/setup-remote.sh your-vps-ip

# Verify connection
kubectl get nodes
kubectl get pods -A
```

## 📁 Structure

```
vps/
├── install.sh              # Main installation script
├── scripts/
│   ├── setup-remote.sh     # Configure local kubectl
│   ├── setup-secrets.sh    # Secrets management
│   ├── setup-ingress.sh    # Ingress with optional TLS
│   ├── export-secrets.sh   # Export credentials securely
│   └── onboard-app.sh      # Onboard new applications
├── namespaces/
│   └── infrastructure.yaml # storage, security, monitoring
└── values/
    ├── postgresql.yaml
    ├── keycloak.yaml
    ├── prometheus.yaml
    └── grafana.yaml
```

## 🔧 Configuration

### Environment Variables

Customize installation by setting these before running `install-k3s.sh`:

```bash
export K3S_VERSION="v1.29.0+k3s1"
export INSTALL_PROMETHEUS=true
export INSTALL_GRAFANA=true
export INSTALL_KEYCLOAK=true
export INSTALL_POSTGRESQL=true
```

### Passwords

Passwords are **auto-generated** during installation and stored securely:

```bash
# View all credentials
cat ~/.k3s-secrets/credentials.env

# Or use the helper script
./vps/scripts/export-secrets.sh show

# Rotate all secrets
./vps/scripts/setup-secrets.sh rotate
```

## 📊 Accessing Services

### Port Forwarding (Recommended for admin)

```bash
# Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80
# Access: http://localhost:3000

# Keycloak
kubectl port-forward -n security svc/keycloak 8080:80
# Access: http://localhost:8080

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Access: http://localhost:9090
```

### Ingress (For production)

Configure Ingress resources for external access. Example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
    name: grafana
    namespace: monitoring
spec:
    ingressClassName: nginx
    rules:
        -   host: grafana.yourdomain.com
            http:
                paths:
                    -   path: /
                        pathType: Prefix
                        backend:
                            service:
                                name: grafana
                                port:
                                    number: 80
```

## 🗄️ PostgreSQL Features

### pg_stat_statements (Slow Query Monitoring)

```sql
-- Connect to PostgreSQL
kubectl
exec -it -n storage postgresql-0 -- psql -U appuser -d appdb

-- View slowest queries
SELECT round(total_exec_time::numeric, 2) as total_time_ms,
       calls,
       round(mean_exec_time::numeric, 2)  as mean_time_ms,
       query
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 10;
```

### WAL Archiving

WAL files are archived to `/bitnami/postgresql/wal_archive/` for point-in-time recovery.

### Automated Backups

Backups run daily at 03:00 UTC with 30-day retention:

```bash
# Check backup CronJob
kubectl get cronjobs -n storage

# View backup logs
kubectl logs -n storage job/postgres-backup-<timestamp>

# List backups
kubectl exec -it -n storage postgresql-0 -- ls -la /backups/
```

## 🚢 Deploying Your Application

### 1. Create Application Namespaces

Application namespaces are NOT pre-created. Use the generic script:

```bash
# Create namespaces for your application
./scripts/create-app-namespaces.sh myapp

# This creates:
# - myapp-prod (with resource quotas)
# - myapp-alpha (with resource quotas)
```

### 2. Deploy with Helm

```bash
# From your application repository
helm install myapp-alpha ./helm/myapp \
  -n myapp-alpha \
  -f ./helm/myapp/values-alpha.yaml

helm install myapp-prod ./helm/myapp \
  -n myapp-prod \
  -f ./helm/myapp/values-prod.yaml
```

## 🔒 Security Considerations

1. **Firewall**: Only open necessary ports (22, 80, 443, 6443)
2. **SSH**: Use key-based authentication, disable password login
3. **Secrets**: Change all default passwords
4. **Network Policies**: Pre-configured to restrict pod-to-pod communication
5. **Resource Quotas**: Prevent runaway resource consumption

## 🛠️ Maintenance

### Update K3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.30.0+k3s1" sh -
```

### Update Helm Charts

```bash
helm repo update
helm upgrade postgresql bitnami/postgresql -n storage -f vps/values/postgresql.yaml
```

### View Logs

```bash
# K3s logs
journalctl -u k3s -f

# Pod logs
kubectl logs -n <namespace> -f deploy/<deployment>
```

## 🆘 Troubleshooting

### K3s not starting

```bash
systemctl status k3s
journalctl -u k3s --no-pager | tail -50
```

### Pods stuck in Pending

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace>
```

### Out of memory

```bash
kubectl top nodes
kubectl top pods -A
```

### Cannot connect from local machine

```bash
# Check firewall
ufw status

# Allow K3s API
ufw allow 6443/tcp
```
