# 🚀 VPS Deployment Guide

Complete guide for deploying k3d-stack infrastructure on a VPS.

## Prerequisites

### VPS Requirements

| Requirement | Minimum          | Recommended |
|-------------|------------------|-------------|
| **OS**      | Ubuntu 22.04 LTS | Debian 12   |
| **RAM**     | 4GB              | 6GB         |
| **Disk**    | 40GB SSD         | 80GB SSD    |
| **CPU**     | 2 vCPU           | 4 vCPU      |

### Required Ports

```
22    - SSH
80    - HTTP (Ingress)
443   - HTTPS (Ingress)
6443  - K3s API
```

### Local Machine

- `kubectl` installed
- `helm` installed (optional, for app deployments)
- SSH key-based access to VPS

---

## Installation Steps (vps first)

### 1. Connect to VPS and Clone Repository

```bash
ssh root@<VPS-IP>

# Clone the repository
git clone https://github.com/DevDeNiro/k3s-stack.git
cd k3s-stack
```

### 2. Run Installation Script (on vps)

```bash
chmod +x vps/install.sh
sudo ./vps/install.sh
```

This will:

1. Install K3s (lightweight Kubernetes)
2. Install Helm
3. Create infrastructure namespaces
4. **Generate secure secrets** (passwords saved to `~/.k3s-secrets/credentials.env`)
5. Deploy: PostgreSQL, Keycloak, Prometheus, Grafana, Ingress NGINX
6. Setup PostgreSQL backup CronJob

### 3. Setup TLS with cert-manager (optional but recommended)

```bash
./vps/scripts/setup-cert-manager.sh
```

Installs cert-manager and creates ClusterIssuers for Let's Encrypt (staging + prod).

### 4. Configure Ingress (with your domain)

```bash
# HTTP only
./vps/scripts/setup-ingress.sh --domain yourdomain.com

# HTTPS (requires step 3)
./vps/scripts/setup-ingress.sh --domain yourdomain.com --tls
```

### 5. Configure DNS

Add DNS records pointing to your VPS IP:

```
grafana.yourdomain.com     A    <VPS-IP>
auth.yourdomain.com        A    <VPS-IP>
prometheus.yourdomain.com  A    <VPS-IP>

# Or use a wildcard:
*.yourdomain.com           A    <VPS-IP>
```

### 6. Configure the GitHub token (hidden input)

```bash
sudo ./vps/scripts/export-secrets.sh set-github-token
```

### 7. Onboard the target application to be deployed

```bash
sudo ./vps/scripts/onboard-app.sh <app-name>
```

This script prepares the cluster for a new application:
- Creates namespaces (`<app-name>-alpha` and `<app-name>-prod`)
- Creates dedicated PostgreSQL databases and users
- Registers the app with ArgoCD (connects to GitLab remote)
- Applies network policies for inter-namespace communication

### 8. Export the sealed-secrets certificate to /tmp/

```bash
sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem
```

(then, after exporting it to your local machine, remember to `rm /tmp/sealed-secrets-pub.pem`)

### 9. Verifications

````
sudo kubectl get pods -A
sudo kubectl get networkpolicies -A
sudo kubectl get ingress -A
````

---

## Then, On your local machine :

### 1. Retrieve the sealed-secrets certificate

```
mkdir -p ~/.k3s-secrets
scp ubuntu@<VPS_IP>:/tmp/sealed-secrets-pub.pem ~/.k3s-secrets/
```

### 2. Delete the temporary file on the VPS

``` ssh ubuntu@<VPS_IP> "rm /tmp/sealed-secrets-pub.pem" ```

### 3. Generate sealed secrets for <YOUR-APP>

#### 3.1 : On your local machine

```
export SEALED_SECRETS_CERT=~/.k3s-secrets/sealed-secrets-pub.pem
export GHCR_USER="<YOUR-GH-NAME>"  # Your GitHub username
export GHCR_TOKEN="ghp_xxx"   # Your GitHub PAT
export PG_PASSWORD="xxx"       # From: sudo ./vps/scripts/export-secrets.sh show <APP-NAME>
export KC_CLIENT_SECRET="xxx"  # From Keycloak UI
```

#### 3.2 : exec:

```
cd ~/Workspace/<YOUR-APP>
./scripts/seal-secrets.sh all <APP-NAME>-alpha --cert $SEALED_SECRETS_CERT
./scripts/seal-secrets.sh all <APP-NAME>-prod --cert $SEALED_SECRETS_CERT
```

#### 3.3 : copie the content of the output on corresponding values.yaml files :

### 4. Commit & push the sealed secrets

```
git add helm/<YOUR-APP>/environments/
git commit -m "chore: update sealed secrets"
git push
```

## Accessing Services

### Via Port-Forward (Recommended for admin)

```bash
# Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80
# Open: http://localhost:3000

# Keycloak
kubectl port-forward -n security svc/keycloak 8080:80
# Open: http://localhost:8080

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Open: http://localhost:9090
```

### Via Ingress (After DNS configuration)

| Service    | URL                               |
|------------|-----------------------------------|
| Grafana    | https://grafana.yourdomain.com    |
| Keycloak   | https://auth.yourdomain.com       |
| Prometheus | https://prometheus.yourdomain.com |

---

## Credentials

All credentials are generated securely and stored in:

```bash
~/.k3s-secrets/credentials.env
```

View credentials:

```bash
cat ~/.k3s-secrets/credentials.env
```

Or use the helper script:

```bash
./vps/scripts/export-secrets.sh show
```

### Rotate Credentials

⚠️ **Warning**: This will require restarting all services.

```bash
./vps/scripts/setup-secrets.sh rotate
```

---

## Deploying Your Application

See [Application Deployment Guide](app-deployment-guide.md) for detailed instructions.

Quick start:

```bash
# 1. Onboard your app (creates namespaces, DB, secrets)
sudo ./vps/scripts/onboard-app.sh myapp

# 2. Deploy with Helm (from your app repository)
helm install myapp-alpha ./helm/myapp \
    -n myapp-alpha \
    -f ./helm/myapp/values-alpha.yaml
```

---

## Firewall Configuration

If using UFW:

```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 6443/tcp  # K3s API
ufw enable
```

---

## Maintenance

### Update K3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.30.0+k3s1" sh -
```

### Update Helm Charts

```bash
helm repo update

# PostgreSQL
helm upgrade postgresql bitnami/postgresql \
    -n storage \
    -f vps/values/postgresql.yaml

# Grafana
helm upgrade grafana grafana/grafana \
    -n monitoring \
    -f vps/values/grafana.yaml
```

### View Logs

```bash
# K3s system logs
journalctl -u k3s -f

# Pod logs
kubectl logs -n <namespace> -f deploy/<deployment>
```

### Backup PostgreSQL

Backups run daily at 03:00 UTC. Manual backup:

```bash
kubectl create job --from=cronjob/postgres-backup manual-backup -n storage
kubectl logs -n storage job/manual-backup -f
```

---

## Troubleshooting

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
# On VPS: Check firewall
ufw status

# Ensure port 6443 is open
ufw allow 6443/tcp

# Test connectivity
curl -k https://<VPS-IP>:6443
```

### TLS Certificate not issued

```bash
# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager

# Check certificate status
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```
