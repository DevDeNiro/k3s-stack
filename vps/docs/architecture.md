# Architecture & Concepts

## Séparation Alpha / Prod

Chaque application onboardée via `onboard-app.sh` dispose de :

| Ressource       | Alpha         | Prod                     |
|-----------------|---------------|--------------------------|
| Namespace       | `<app>-alpha` | `<app>-prod`             |
| Database        | `<app>-alpha` | `<app>-prod`             |
| User PostgreSQL | `<app>-alpha` | `<app>-prod`             |
| Backup auto     | ❌             | ✅ (daily/weekly/monthly, copie hors site optionnelle) |

### Workflow Git → Environnement

| Branche   | Namespace     | Tag de l'image             |
|-----------|---------------|----------------------------|
| `develop` | `<app>-alpha` | `develop-<sha complet>`    |
| `main`    | `<app>-prod`  | `main-<sha complet>`       |

Le préfixe de branche empêche qu'un build d'une branche soit déployé dans l'autre
environnement. L'Application alpha n'existe que si le dépôt a une branche `develop`
contenant `helm/` : un dépôt sans `develop` n'a qu'un environnement de production.

### Plusieurs organisations GitHub

Les ApplicationSets ont un générateur SCM par organisation de `SCM_ORGANIZATIONS`
(`config.env`), avec un seul token (`export-secrets.sh set-scm-credentials`). Chaque
générateur porte le chemin des images de son organisation (`values.imageBase`) :
`REGISTRY_HOST/<organisation en minuscules>`, ou `REGISTRY_BASE` pour une organisation
unique. Les chemins GHCR sont en minuscules ; les noms de dépôt doivent être en
minuscules et uniques entre les organisations (ils nomment les Applications et les
namespaces). `onboard-app.sh --organization <org>` crée le Secret de dépôt Argo CD du
bon `<org>/<app>`.

---

## ArgoCD Image Updater

Depuis la v1.1.0, l'Image Updater utilise des **Custom Resources** pour détecter les nouvelles images.

```
ImageUpdater CR → Lit annotations Application → Met à jour image.tag
```

**Fichiers clés** :

- `vps/manifests/argocd-image-updaters.yaml` - CRs pour `*-alpha` et `*-prod`
- `vps/templates/argocd/applicationsets.yaml.tpl` - ApplicationSets et annotations de
  l'Image Updater (rendus par `scripts/apply-config.sh`), image
  `{{values.imageBase}}/{{repository}}`
- `vps/templates/argocd/generator-{alpha,prod}.yaml.tpl` - un générateur par organisation

### Stratégies

**Alpha** : `newest-build` + filtre `regexp:^develop-[a-f0-9]{40}$`

**Prod** : `newest-build` + filtre `regexp:^main-[a-f0-9]{40}$`

Le tag retenu est écrit dans l'Application Argo CD (`write-back-method: argocd`), sans
commit Git.

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
    -   name: common-library
        version: "2.1.0"
        repository: "oci://ghcr.io/devdeniro"
```

```yaml
# templates/migration-job.yaml
{ { - include "common.migrationJob.springBoot" . } }
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

| Env   | Realm         | URL                                          |
|-------|---------------|----------------------------------------------|
| Alpha | `<app>-alpha` | `https://auth.domain.com/realms/<app>-alpha` |
| Prod  | `<app>-prod`  | `https://auth.domain.com/realms/<app>-prod`  |

### Créer un realm (CLI)

Le mot de passe administrateur transite par stdin (jamais en argument de `kubectl exec`,
enregistré par le journal d'audit) :

```bash
kubectl get secret keycloak-secret -n security -o jsonpath='{.data.admin-password}' | base64 -d \
  | kubectl exec -i -n security keycloak-0 -- sh -c '
      IFS= read -r password
      /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
          --user admin --password "$password" --config /tmp/kcadm.config &&
      /opt/keycloak/bin/kcadm.sh create realms -s realm="$1" -s enabled=true --config /tmp/kcadm.config
      rm -f /tmp/kcadm.config' kcadm <app>-alpha
```

Le mot de passe initial ne sert qu'au premier démarrage : s'il a été changé dans la
console, utiliser le mot de passe courant.

### Thèmes et providers (images d'extension)

Keycloak garde l'image officielle. Les thèmes et les providers viennent d'images listées
dans `KEYCLOAK_EXTENSION_IMAGES` (`config.env`) : à chaque démarrage, un initContainer
par image copie `/themes/<nom>/` dans `/opt/keycloak/themes` et `/providers/*.jar` dans
`/opt/keycloak/providers` (contrat de l'image : [`../README.md`](../README.md#keycloak-extension-images)).
Keycloak démarre sans `--optimized` et se reconstruit lui-même quand les providers
changent. Après une modification des images :

```bash
sudo ./vps/scripts/apply-keycloak.sh       # rendu, application, redémarrage (1 à 2 minutes)
```

Une référence porte un tag immuable ou un digest : un tag n'est tiré qu'une fois par
nœud. Les images privées utilisent le Secret `security/ghcr-secret`
(`export-secrets.sh set-scm-credentials github`).

### Emails du realm et limite de débit

La NetworkPolicy de Keycloak autorise la sortie SMTP (587 avec STARTTLS, 465) vers les
adresses publiques : invitations, réinitialisations et vérifications d'email passent par
un relais SMTP (Scaleway TEM, par exemple). Côté passerelle, la RateLimitPolicy
`keycloak` limite les endpoints OIDC (`/realms`) par adresse cliente
(`KEYCLOAK_RATE_LIMIT_RATE`, `KEYCLOAK_RATE_LIMIT_BURST`, réponse `429`) ; les assets de
connexion (`/resources`) ne sont pas limités. La détection de force brute du realm
protège les comptes en complément.

---

## Firewall (UFW)

Configuré par `install.sh` via `scripts/harden-host.sh` : entrées refusées, SSH limité
en débit, 80/443 ouverts, réseaux de K3s autorisés, **API 6443 fermée** (accès par
tunnel SSH, voir [`workstation-setup.md`](workstation-setup.md)). Aperçu sans rien
modifier : `sudo ./vps/scripts/harden-host.sh`.

---

## Maintenance

### Mise à jour K3s

```bash
sudo ./vps/scripts/k3s-maintenance.sh status
sudo ./vps/scripts/k3s-maintenance.sh upgrade   # sauvegarde, puis mineure suivante
```

### Versions des charts

Épinglées dans `vps/config/versions.env`. Une montée de version se valide localement
(`local/install.sh`) puis s'applique par réinstallation (voir
[`security-hardening.md`](security-hardening.md)).

### Backup PostgreSQL manuel

```bash
kubectl create job --from=cronjob/postgres-backup-daily manual-backup -n storage
kubectl logs -n storage job/manual-backup -f
# copie hors site immédiate (avec OFFSITE_BACKUP_REPOSITORY)
kubectl create job --from=cronjob/postgres-backup-offsite manual-offsite -n storage
```

Copie hors site chiffrée (restic), restauration et exercice : [`postgres-backup.md`](postgres-backup.md).

### Rotation des credentials

```bash
sudo ./vps/scripts/setup-secrets.sh rotate
```

Régénère les mots de passe du superutilisateur PostgreSQL, de la base Keycloak et de
l'administrateur Argo CD, puis redémarre PostgreSQL et Keycloak.
