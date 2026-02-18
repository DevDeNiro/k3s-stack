# Architecture & Concepts

## Séparation Alpha / Prod

Chaque application onboardée via `onboard-app.sh` dispose de :

| Ressource | Alpha | Prod |
|-----------|-------|------|
| Namespace | `<app>-alpha` | `<app>-prod` |
| Database | `<app>-alpha` | `<app>-prod` |
| User PostgreSQL | `<app>-alpha` | `<app>-prod` |
| Backup auto | ❌ | ✅ (daily/weekly/monthly) |

### Workflow Git → Environnement

| Branche | Namespace | Tag Strategy |
|---------|-----------|--------------|
| `develop` | `<app>-alpha` | SHA (`sha-7b3f1a`) |
| `main` | `<app>-prod` | SemVer (`v1.0.0`) |

---

## ArgoCD Image Updater

Depuis la v1.1.0, l'Image Updater utilise des **Custom Resources** pour détecter les nouvelles images.

```
ImageUpdater CR → Lit annotations Application → Met à jour image.tag
```

**Fichiers clés** :
- `manifests/argocd-image-updater-crs.yaml` - CRs pour `*-alpha` et `*-prod`
- `manifests/argocd-autodiscover.yaml` - ApplicationSets avec annotations

### Stratégies

**Alpha** : `newest-build` + filtre `regexp:^([a-f0-9]{7,40}|sha-[a-f0-9]{7,40})$`

**Prod** : `newest-build` + filtre `regexp:^(v?[0-9]+\.[0-9]+\.[0-9]+.*|sha-[a-f0-9]{7,40})$`

---

## Secrets PostgreSQL (GitOps)

```
onboard-app.sh
    ├─► Crée DB + user PostgreSQL
    ├─► Sauvegarde password → /root/.k3s-secrets/<app>.env
    └─► Crée secret K8s temporaire

SealedSecret (dans votre chart)
    └─► ArgoCD déploie → Sealed Secrets déchiffre → Secret final
```

**Configuration values.yaml** :

```yaml
database:
    host: postgresql.storage.svc.cluster.local
    port: 5432
    name: <app>-alpha
    username: <app>-alpha
    existingSecret: <app>-db
    secretKey: password
```

---

## Migrations (ArgoCD PreSync)

Les migrations s'exécutent **avant** le déploiement via un Job PreSync.

### Avec common-library

```yaml
# Chart.yaml
dependencies:
    - name: common-library
      version: "2.1.0"
      repository: "oci://ghcr.io/devdeniro"
```

```yaml
# templates/migration-job.yaml
{{- include "common.migrationJob.springBoot" . }}
```

```yaml
# values-prod.yaml
migration:
    enabled: true
    type: liquibase
    springProfile: migration  # Profil dédié sans web/security
```

### Profil Spring dédié (recommandé pour prod)

```yaml
# application-migration.yml
spring:
    main:
        web-application-type: none
        lazy-initialization: true
    autoconfigure:
        exclude:
            - org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
            - org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration
```

### Vérification

```bash
kubectl get jobs -n <app>-alpha -l app.kubernetes.io/component=migration
kubectl logs -n <app>-alpha job/<app>-migration-<revision>
```

---

## Keycloak (Multi-Realm)

Une instance Keycloak, un realm par environnement :

| Env | Realm | URL |
|-----|-------|-----|
| Alpha | `<app>-alpha` | `https://auth.domain.com/realms/<app>-alpha` |
| Prod | `<app>-prod` | `https://auth.domain.com/realms/<app>-prod` |

### Créer un realm (CLI)

```bash
kubectl exec -it -n security deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin \
  --password "$(kubectl get secret -n security keycloak -o jsonpath='{.data.admin-password}' | base64 -d)"

kubectl exec -it -n security deploy/keycloak -- \
  /opt/keycloak/bin/kcadm.sh create realms -s realm=<app>-alpha -s enabled=true
```

---

## Firewall (UFW)

```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 6443/tcp  # K3s API
ufw enable
```

---

## Maintenance

### Mise à jour K3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.30.0+k3s1" sh -
```

### Mise à jour Helm Charts

```bash
helm repo update
helm upgrade postgresql bitnami/postgresql -n storage -f vps/values/postgresql.yaml
helm upgrade grafana grafana/grafana -n monitoring -f vps/values/grafana.yaml
```

### Backup PostgreSQL manuel

```bash
kubectl create job --from=cronjob/postgres-backup manual-backup -n storage
kubectl logs -n storage job/manual-backup -f
```

### Rotation des credentials

```bash
sudo ./vps/scripts/setup-secrets.sh rotate
```

> ⚠️ Nécessite un restart de tous les services
