# VPS Deployment Guide

## Prérequis

**VPS** : Ubuntu 22.04+ / Debian 12 | 4GB+ RAM | 40GB+ SSD | Ports 22, 80, 443, 6443 ouverts

**Local** : `kubectl`, `helm`, accès SSH au VPS

---

## Installation (sur le VPS)

### 1. Cloner et installer

```bash
ssh root@<VPS-IP>
git clone https://github.com/DevDeNiro/k3s-stack.git
cd k3s-stack

# 1. Éditer config.env avec TES valeurs
nano vps/config.env

chmod +x vps/install.sh
sudo ./vps/install.sh
```

> Installe : K3s, Helm, PostgreSQL, Redis, Keycloak, Prometheus, Grafana, ArgoCD, Sealed Secrets

### 2. Configurer TLS (cert-manager)

```bash
sudo ./vps/scripts/setup-cert-manager.sh --email admin@yourdomain.com
```

### 3. Configurer Gateway API

```bash
sudo ./vps/scripts/setup-gateway-api.sh --domain yourdomain.com
```

### 4. Configurer DNS

```
*.yourdomain.com    A    <VPS-IP>
```

### 5. Configurer le token SCM (GitHub/GitLab)

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

### 6. Onboarder une application

```bash
sudo ./vps/scripts/onboard-app.sh <app-name>
```

> Crée : namespaces `<app>-alpha` et `<app>-prod`, databases PostgreSQL, credentials

### 7. Exporter le certificat Sealed Secrets

```bash
sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem
```

### 8. Vérifier l'installation

```bash
sudo kubectl get pods -A
sudo kubectl get gateways -n nginx-gateway
sudo kubectl get certificates -A
```

---

## Configuration locale

### 1. Récupérer le certificat Sealed Secrets

```bash
mkdir -p ~/.k3s-secrets
scp ubuntu@<VPS_IP>:/tmp/sealed-secrets-pub.pem ~/.k3s-secrets/
ssh ubuntu@<VPS_IP> "rm /tmp/sealed-secrets-pub.pem"
```

### 2. Récupérer les credentials DB

```bash
# Sur le VPS
sudo ./vps/scripts/export-secrets.sh show <app-name>
```

### 3. Générer les Sealed Secrets (dans votre app)

```bash
export SEALED_SECRETS_CERT=~/.k3s-secrets/sealed-secrets-pub.pem
export PG_PASSWORD="<password-from-step-2>"

./scripts/seal-secrets.sh all <app-name>-alpha --cert $SEALED_SECRETS_CERT
```

### 4. Commit & push

```bash
git add helm/
git commit -m "chore: add sealed secrets"
git push
```

---

## Accès aux services

### Port-forward (admin)

```bash
# Grafana
sudo kubectl port-forward -n monitoring svc/grafana 3000:80

# Keycloak Admin
sudo kubectl port-forward -n security svc/keycloak 8080:80

# ArgoCD
sudo kubectl port-forward -n argocd svc/argocd-server 8443:443

# Prometheus
sudo kubectl port-forward -n monitoring svc/prometheus-server 9090:80
```

### SSH tunnel (depuis local)

```bash
ssh -L 8080:localhost:8080 ubuntu@<VPS_IP> "sudo kubectl port-forward -n security svc/keycloak 8080:80"
```

### URLs publiques (Gateway API)

| Service        | URL                                    |
|----------------|----------------------------------------|
| Keycloak OAuth | `https://auth.yourdomain.com/realms/*` |
| Votre app      | `https://app.yourdomain.com`           |

---

## Credentials

```bash
# Voir tous les credentials
sudo ./vps/scripts/export-secrets.sh show

# Credential spécifique
sudo ./vps/scripts/export-secrets.sh show grafana
sudo ./vps/scripts/export-secrets.sh show keycloak
sudo ./vps/scripts/export-secrets.sh show argocd
```

---

## Troubleshooting

### K3s ne démarre pas

```bash
systemctl status k3s
journalctl -u k3s --no-pager | tail -50
```

### Certificat TLS non émis

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
kubectl logs -n cert-manager deploy/cert-manager
```

### Gateway API issues

```bash
kubectl get gateways -n nginx-gateway
kubectl describe gateway infrastructure-gateway -n nginx-gateway
kubectl get httproutes -A
```

---

## Documentation complémentaire

- [Architecture & Concepts](architecture.md) - Séparation alpha/prod, tagging, migrations
- [Database Admin](database-admin.md) - Administration PostgreSQL
- [Commands Cheatsheet](commands-cheatsheet.md) - Commandes kubectl/helm utiles
