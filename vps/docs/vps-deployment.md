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

### 3. Setup TLS with cert-manager

```bash
sudo ./vps/scripts/setup-cert-manager.sh
```

Installs cert-manager and creates ClusterIssuers for Let's Encrypt (staging + prod).

### 4. Configure Ingress for infrastructure services

> **Note**: Cette étape configure l'accès HTTPS aux services d'infrastructure (Grafana, Keycloak, Prometheus).
> Si vous préférez y accéder uniquement via `kubectl port-forward`, vous pouvez passer cette étape.

```bash
# HTTPS avec Let's Encrypt (recommandé)
# Le script détecte automatiquement cert-manager s'il est installé
sudo ./vps/scripts/setup-ingress.sh --domain yourdomain.com --tls

# HTTP uniquement (non recommandé en production)
sudo ./vps/scripts/setup-ingress.sh --domain yourdomain.com
```

Cette commande crée des Ingress pour :

- `grafana.<domain>` → Grafana
- `auth.<domain>` → Keycloak
- `prometheus.<domain>` → Prometheus

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
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
sudo ./vps/scripts/export-secrets.sh set-scm-credentials gitlab
```

### 7. Onboard the target application to be deployed

```bash
sudo ./vps/scripts/onboard-app.sh <app-name>
```

This script prepares the cluster for a new application:

- Creates namespaces (`<app-name>-alpha` and `<app-name>-prod`)
- Creates dedicated PostgreSQL databases and users (un par environnement)
- **Sauvegarde les mots de passe DB** dans `/root/.k3s-secrets/<app-name>.env`
- Creates CI/CD ServiceAccounts and kubeconfigs

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

#### 3.1 : Récupérer les secrets nécessaires

| Secret                | Source                                                 | Description                               |
|-----------------------|--------------------------------------------------------|-------------------------------------------|
| `SEALED_SECRETS_CERT` | Étape 1-2 ci-dessus                                    | Certificat pour sceller les secrets       |
| `GHCR_USER`           | Votre compte GitHub                                    | Username pour pull images                 |
| `GHCR_TOKEN`          | GitHub → Settings → Developer settings → PAT           | Token avec `read:packages`                |
| `PG_PASSWORD`         | VPS: `sudo ./vps/scripts/export-secrets.sh show <app>` | Mot de passe DB généré par onboard-app.sh |
| `KC_CLIENT_SECRET`    | Keycloak Admin UI → Clients → Credentials              | Secret du client OIDC                     |

```bash
# Sur le VPS - récupérer le mot de passe PostgreSQL
sudo ./vps/scripts/export-secrets.sh show <APP-NAME>
# Affiche:
#   <APP-NAME>_ALPHA_DB_PASSWORD=xxx
#   <APP-NAME>_PROD_DB_PASSWORD=xxx
```

#### 3.2 : Définir les variables d'environnement (local)

```bash
export SEALED_SECRETS_CERT=~/.k3s-secrets/sealed-secrets-pub.pem
export GHCR_USER="<YOUR-GH-NAME>"
export GHCR_TOKEN="ghp_xxx"
export PG_PASSWORD="xxx"        # Password ALPHA ou PROD selon l'env
export KC_CLIENT_SECRET="xxx"
```

#### 3.3 : Générer les SealedSecrets

```bash
cd ~/Workspace/<YOUR-APP>

# Pour l'environnement alpha (utiliser le password alpha)
export PG_PASSWORD="<ALPHA_DB_PASSWORD>"
./scripts/seal-secrets.sh all <APP-NAME>-alpha --cert $SEALED_SECRETS_CERT

# Pour l'environnement prod (utiliser le password prod)
export PG_PASSWORD="<PROD_DB_PASSWORD>"
./scripts/seal-secrets.sh all <APP-NAME>-prod --cert $SEALED_SECRETS_CERT
```

#### 3.4 : Copier les valeurs scellées dans values-alpha.yaml et values-prod.yaml

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
sudo kubectl port-forward -n monitoring svc/grafana 3000:80
# Open: http://localhost:3000

# Keycloak
sudo kubectl port-forward -n security svc/keycloak 8080:80
# Open: http://localhost:8080
ssh -L 8080:localhost:8080 ubuntu@<VPS_IP> "sudo kubectl port-forward -n security svc/keycloak 8080:80"

# Prometheus
sudo kubectl port-forward -n monitoring svc/prometheus-server 9090:80
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
sudo ./vps/scripts/export-secrets.sh show
```

### Rotate Credentials

⚠️ **Warning**: This will require restarting all services.

```bash
sudo ./vps/scripts/setup-secrets.sh rotate
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

Voir projet exemple (TODO)

---

## Environment Separation (Alpha / Prod)

### Architecture

Chaque application déployée via `onboard-app.sh` dispose de:

- **2 namespaces**: `<app>-alpha` et `<app>-prod`
- **2 bases de données séparées**: `<app>-alpha` et `<app>-prod`
- **2 utilisateurs PostgreSQL distincts**: chacun avec son propre mot de passe

Cette séparation garantit l'isolation totale des données entre les environnements.

### Workflow Git → Environnement

| Branche Git | Namespace cible | Base de données |
|-------------|-----------------|-----------------|
| `develop`   | `<app>-alpha`   | `<app>-alpha`   |
| `main`      | `<app>-prod`    | `<app>-prod`    |

### Secrets de connexion DB

**Important**: Le script `onboard-app.sh` crée un secret Kubernetes temporaire, mais pour GitOps/ArgoCD, vous devez *
*sceller le mot de passe** et le stocker dans votre chart Helm.

**Flow des secrets PostgreSQL:**

```
onboard-app.sh
    │
    ├─► Crée DB + user dans PostgreSQL
    ├─► Sauvegarde password dans /root/.k3s-secrets/<app>.env
    └─► Crée secret K8s temporaire (sera écrasé par ArgoCD)

SealedSecret (dans votre chart Helm)
    │
    └─► ArgoCD déploie → Sealed Secrets Controller déchiffre
        └─► Crée le secret <app>-db final
```

**Configuration dans values.yaml:**

```yaml
database:
    host: postgresql.storage.svc.cluster.local
    port: 5432
    name: <app>-alpha           # ou <app>-prod
    username: <app>-alpha       # correspond au nom de la DB
    existingSecret: <app>-db    # secret créé par SealedSecret
    secretKey: password
```

---

## Database Migrations with ArgoCD PreSync Hooks

### Principe

ArgoCD permet d'exécuter des **Jobs de migration** avant chaque déploiement grâce aux hooks PreSync. Cela garantit que
le schéma de la base est toujours à jour avant que l'application ne démarre.

### Intégration dans votre Chart Helm

1. **Copiez le template** depuis `vps/docs/examples/migration-job-presync.yaml` vers votre chart:

```bash
cp k3s-stack/vps/docs/examples/migration-job-presync.yaml \
   <app>/helm/<app>/templates/migration-job.yaml
```

2. **Adaptez le template** à votre application (remplacez `<app>` par le nom de votre chart et ajustez la commande de
   migration).

3. **Choisissez votre stratégie de migration**:

    - **Spring Boot + Flyway**: L'application elle-même exécute les migrations au démarrage
    - **Flyway CLI**: Image dédiée avec `flyway migrate`
    - **Liquibase**: Image dédiée avec `liquibase update`
    - **Script custom**: Script shell personnalisé

### Exemple: Spring Boot avec Flyway

```yaml
# templates/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
    name: { { include "myapp.fullname" . } }-migration-{{ .Release.Revision }}
    annotations:
        argocd.argoproj.io/hook: PreSync
        argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
    template:
        spec:
            restartPolicy: Never
            containers:
                -   name: migration
                    image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
                    env:
                        -   name: SPRING_DATASOURCE_URL
                            valueFrom:
                                secretKeyRef:
                                    name: myapp-db
                                    key: url
                        -   name: SPRING_DATASOURCE_USERNAME
                            valueFrom:
                                secretKeyRef:
                                    name: myapp-db
                                    key: username
                        -   name: SPRING_DATASOURCE_PASSWORD
                            valueFrom:
                                secretKeyRef:
                                    name: myapp-db
                                    key: password
                        -   name: SPRING_MAIN_WEB_APPLICATION_TYPE
                            value: "none"
                        -   name: SPRING_FLYWAY_ENABLED
                            value: "true"
```

### Vérification des migrations

```bash
# Voir les jobs de migration
kubectl get jobs -n myapp-alpha -l app.kubernetes.io/component=migration

# Logs d'une migration
kubectl logs -n myapp-alpha job/myapp-migration-5

# En cas d'échec, le job reste pour debug
kubectl describe job -n myapp-alpha myapp-migration-5
```

---

## Keycloak Realm Separation (Alpha / Prod)

### Stratégie recommandée: Une instance, plusieurs realms

Plutôt que de dupliquer Keycloak (ce qui consommerait ~1.5GB RAM supplémentaire), nous utilisons **un realm par
environnement** dans une instance partagée.

| Environnement | Realm Keycloak  | URL Auth                                        |
|---------------|-----------------|-------------------------------------------------|
| Alpha         | `coterie-alpha` | `https://auth.example.com/realms/coterie-alpha` |
| Prod          | `coterie-prod`  | `https://auth.example.com/realms/coterie-prod`  |

### Création des realms

#### Via l'interface Admin UI

1. Accédez à Keycloak Admin Console:
   ```bash
   kubectl port-forward -n security svc/keycloak 8080:80
   # Ouvrir http://localhost:8080/admin
   ```

2. Créez un realm pour chaque environnement:
    - Cliquez sur le dropdown du realm (en haut à gauche) → "Create Realm"
    - Nom: `coterie-alpha` (puis répétez pour `coterie-prod`)

3. Dans chaque realm, créez un client OIDC pour votre application:
    - Clients → Create client
    - Client ID: `<app>-frontend` ou `<app>-backend`
    - Configurez les redirect URIs selon l'environnement

#### Via kcadm (CLI)

```bash
# Se connecter
kubectl exec -it -n security deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "$(kubectl get secret -n security keycloak -o jsonpath='{.data.admin-password}' | base64 -d)"

# Créer le realm alpha
kubectl exec -it -n security deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=coterie-alpha \
  -s enabled=true

# Créer le realm prod
kubectl exec -it -n security deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=coterie-prod \
  -s enabled=true
```

### Configuration dans votre application

Créez des secrets distincts pour chaque environnement avec les URLs appropriées:

```yaml
# values-alpha.yaml
keycloak:
    issuerUri: https://auth.example.com/realms/coterie-alpha
    clientId: myapp-frontend

# values-prod.yaml
keycloak:
    issuerUri: https://auth.example.com/realms/coterie-prod
    clientId: myapp-frontend
```

### Bonnes pratiques

1. **Isolation des utilisateurs**: Chaque realm a sa propre base d'utilisateurs. Les utilisateurs de test (alpha) ne
   peuvent pas accéder à la production.

2. **Client secrets distincts**: Générez des client secrets différents pour alpha et prod.

3. **Tokens différents**: Les tokens émis par un realm ne sont pas valides pour l'autre.

4. **Export/Import**: Vous pouvez exporter la configuration d'un realm et l'importer dans l'autre pour répliquer les
   settings:
   ```bash
   # Export
   kubectl exec -it -n security deploy/keycloak -- \
     /opt/keycloak/bin/kc.sh export --realm coterie-alpha --dir /tmp/export
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
