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

> Installe : K3s, Helm, Gateway API (NGINX Gateway Fabric), PostgreSQL, Redis, Keycloak, Prometheus, Grafana, ArgoCD,
> Sealed Secrets

**Variables importantes dans `config.env` :**

- `DOMAIN` : ton domaine (ex: `example.com`)
- `LETSENCRYPT_EMAIL` : email pour Let's Encrypt
- `SCM_ORGANIZATION` : ton organisation GitHub/GitLab
- `REGISTRY_BASE` : base URL de ton registry (ex: `ghcr.io/your-org`)

### 2. Configurer TLS (cert-manager)

```bash
sudo ./vps/scripts/setup-cert-manager.sh --email admin@yourdomain.com
```

### 3. Configurer Gateway API

```bash
sudo ./vps/scripts/setup-gateway-api.sh --domain yourdomain.com
```

### 4. Configurer CoreDNS (hairpin NAT)

```bash
sudo ./vps/scripts/setup-coredns-hosts.sh --domain yourdomain.com
```

> Configure CoreDNS pour résoudre `auth.<domain>` vers Keycloak en interne.
> Nécessaire pour que les pods puissent accéder à Keycloak via l'URL externe.

### 5. Configurer DNS

```
*.yourdomain.com    A    <VPS-IP>
```

### 6. Configurer le token SCM (GitHub/GitLab)

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

### 7. Onboarder une application

```bash
# Avec subdomains par défaut (alpha.domain, app.domain)
sudo ./vps/scripts/onboard-app.sh <app-name>

# Avec subdomains personnalisés
SUBDOMAIN_ALPHA=staging SUBDOMAIN_PROD=www sudo ./vps/scripts/onboard-app.sh <app-name>

# Sans configuration Gateway (si déjà fait manuellement)
SKIP_GATEWAY=true sudo ./vps/scripts/onboard-app.sh <app-name>
```

> Crée automatiquement :
> - Namespaces `<app>-alpha` et `<app>-prod` avec ResourceQuotas
> - Databases PostgreSQL séparées par environnement
> - Certificats TLS (Let's Encrypt HTTP-01)
> - Listeners HTTPS sur le Gateway
> - Secrets GHCR et ServiceAccounts CI/CD

### 8. Exporter le certificat Sealed Secrets

```bash
sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem
```

### 9. Vérifier l'installation

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

| Service        | URL                                    | Notes                        |
|----------------|----------------------------------------|------------------------------|
| Keycloak OAuth | `https://auth.yourdomain.com/realms/*` | /admin bloqué (port-forward) |
| App Alpha      | `https://alpha.yourdomain.com`         | Environnement staging        |
| App Prod       | `https://app.yourdomain.com`           | Environnement production     |

> **Note** : Les certificats sont émis par Let's Encrypt via HTTP-01 challenge (pas de wildcard).

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

## ArgoCD Auto-Discovery

L'installation configure automatiquement l'auto-découverte des applications via ApplicationSets.

### Fonctionnement

1. ArgoCD scanne ton organisation GitHub/GitLab
2. Les repos avec un dossier `helm/` sont détectés automatiquement
3. Deux Applications sont créées : `<repo>-alpha` (branche develop) et `<repo>-prod` (branche main)

### Prérequis pour un repo

Structure attendue :

```
<repo>/
  helm/
    <repo>/
      Chart.yaml
      values.yaml
      values-alpha.yaml
      values-prod.yaml
      templates/
```

### Vérification

```bash
# Voir les ApplicationSets
kubectl get applicationsets -n argocd

# Voir les Applications générées
kubectl get applications -n argocd

# Logs du controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50
```

### Problèmes fréquents

**"generated 0 applications"** :

- Vérifier que le dossier `helm/` existe dans le repo
- Le token SCM doit avoir accès au repo (scope `repo` ou `Contents: read`)
- Le filtre utilise `pathsExist: ["helm"]` (les globs ne sont PAS supportés)

**"Secret scm-token not found"** :

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

**"Unable to resolve issuer" / "Connection refused" sur Keycloak** :
Le hairpin NAT empêche les pods d'atteindre `auth.<domain>` via l'IP externe.
Cela est résolu automatiquement par `configure_coredns_internal_hosts()` dans install.sh.

Si nécessaire, vérifier CoreDNS :

```bash
kubectl get configmap coredns -n kube-system -o yaml | grep NodeHosts -A5
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
# État du Gateway et listeners
kubectl get gateways -n nginx-gateway
kubectl describe gateway infrastructure-gateway -n nginx-gateway

# HTTPRoutes
kubectl get httproutes -A

# Pods NGINX (data plane)
kubectl get pods -n nginx-gateway
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric
```

### Certificat bloqué en Pending

```bash
# Vérifier l'état
kubectl get certificates -n nginx-gateway
kubectl describe certificate <name> -n nginx-gateway

# Vérifier les challenges HTTP-01
kubectl get challenges -A
kubectl describe challenge <name> -n nginx-gateway

# Logs cert-manager
kubectl logs -n cert-manager deploy/cert-manager --tail=50
```

> **Cause fréquente** : DNS pas encore propagé ou port 80 bloqué.

---

## Documentation complémentaire

- [Architecture & Concepts](architecture.md) - Séparation alpha/prod, tagging, migrations
- [Database Admin](database-admin.md) - Administration PostgreSQL
- [Commands Cheatsheet](commands-cheatsheet.md) - Commandes kubectl/helm utiles
