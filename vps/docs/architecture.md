# Architecture & Concepts

## Séparation Alpha / Prod

Selon les options de `onboard-app.sh`, chaque environnement sélectionné dispose de :

| Ressource       | Alpha         | Prod                     |
|-----------------|---------------|--------------------------|
| Namespace       | `<app>-alpha` | `<app>-prod`             |
| Pod Security    | `restricted`  | `restricted`             |
| NetworkPolicy par défaut | `k3s-stack-default-ingress` | `k3s-stack-default-ingress` |
| Database        | `<app>-alpha` | `<app>-prod`             |
| User PostgreSQL | `<app>-alpha` | `<app>-prod`             |
| AppProject Argo CD | `<app>` (commun) | `<app>` (commun)   |
| Backup auto     | ❌             | ✅ (daily/weekly/monthly, copie hors site optionnelle) |

`--environment` sélectionne les environnements ; `--skip-database` désactive la base.
L'onboarding ne crée pas les realms Keycloak.

### Cloisonnement entre applications

Une application n'accède qu'à ce que son onboarding lui donne :

- **Argo CD** : son AppProject n'autorise que son dépôt et ses deux namespaces, aucune
  ressource de niveau cluster, ni `ResourceQuota`, `LimitRange`, `Endpoints` ou
  `EndpointSlice`. Argo CD ne crée ni projet ni namespace : sans onboarding, rien n'est
  déployé. Le projet `default` est vidé.
- **Réseau** : ses pods n'acceptent que les connexions de sa namespace, de la passerelle et
  de Prometheus ; `monitoring` et `argocd` n'acceptent que leurs propres pods.
- **Passerelle** : chaque hostname appartient aux namespaces déclarées dans
  `GATEWAY_HOSTNAMES` (`<hostname>=<namespace>`) ; une route d'une autre namespace est
  refusée.
- **Données** : son rôle PostgreSQL ne se connecte qu'à sa base, son realm Keycloak lui
  est propre ; un cache (Redis) vit dans son chart, dans sa namespace.
- **Secrets** : tout chart lit les Secrets de sa namespace ; ils ne contiennent que ses
  identifiants et un jeton de lecture des images. Aucun identifiant d'administration de la
  plateforme (realm `master`, Argo CD, superutilisateur PostgreSQL) n'y est déposé.

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
(`config.env`), avec un jeton de dépôt pour toutes (`export-secrets.sh set-scm-credentials`,
namespace `argocd` seulement) et un jeton de lecture des images pour toutes
(`export-secrets.sh set-registry-credentials`, copié dans chaque namespace applicative).
Chaque générateur porte le chemin des images de son organisation (`values.imageBase`) :
`REGISTRY_HOST/<organisation en minuscules>`, ou `REGISTRY_BASE` pour une organisation
unique. Les chemins GHCR sont en minuscules ; les noms de dépôt doivent être en
minuscules et uniques entre les organisations (ils nomment les Applications, les
AppProjects et les namespaces). `onboard-app.sh --organization <org>` crée le Secret de
dépôt Argo CD et l'AppProject du bon `<org>/<app>`.

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
commit Git. Alpha se synchronise automatiquement ; la production nécessite une
synchronisation manuelle après vérification du tag et de la révision Git. Avant la
sélection d'un tag immuable, l'Application utilise le tag initial `develop` ou `main`.

---

## Secrets PostgreSQL

```
onboard-app.sh
    ├─► Crée DB + user PostgreSQL
    ├─► Sauvegarde password → /root/.k3s-secrets/<app>.env
    └─► Crée le Secret K8s <app>-db dans chaque namespace sélectionnée
```

Le Secret PostgreSQL est créé directement par l'onboarding et n'a pas à être remplacé
par un SealedSecret. Sauvegarder le mot de passe hors du serveur, sans le publier dans
Git. Les autres secrets applicatifs peuvent être scellés séparément.

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

Un Job PreSync facultatif s'exécute avant le déploiement. Ses Secrets doivent exister
avant la phase Sync. La [bibliothèque Helm](../../charts/common-library/templates/_migration-job.tpl)
fournit des modèles ; vérifier notamment la configuration TLS et la sortie du processus
de migration pour le chart de l'application.

---

## Keycloak (Multi-Realm)

Une instance Keycloak, un realm par environnement :

| Env   | Realm         | URL                                          |
|-------|---------------|----------------------------------------------|
| Alpha | `<app>-alpha` | `https://auth.domain.com/realms/<app>-alpha` |
| Prod  | `<app>-prod`  | `https://auth.domain.com/realms/<app>-prod`  |

Les realms se configurent séparément dans la console, accessible par tunnel :
voir [`installation-onboarding.md`](installation-onboarding.md#7-configurer-lidentité-et-les-secrets-de-lapplication).
Le mot de passe initial ne sert qu'au premier démarrage ; utiliser le mot de passe courant.

Ce compte du realm `master` administre tous les realms : il reste à l'opérateur et ne
va jamais dans une application. Une application qui gère les utilisateurs de son realm
utilise un client confidentiel de ce realm avec compte de service, limité aux rôles
`realm-management` dont elle a besoin (`manage-users`, `view-users`...).

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
(`export-secrets.sh set-registry-credentials`).

### Emails du realm et limite de débit

La NetworkPolicy de Keycloak autorise la sortie SMTP (587 avec STARTTLS, 465) vers les
adresses publiques : invitations, réinitialisations et vérifications d'email passent par
un relais SMTP (Scaleway TEM, par exemple). Côté passerelle, la RateLimitPolicy
`keycloak` limite les endpoints OIDC (`/realms`) par adresse cliente
(`KEYCLOAK_RATE_LIMIT_RATE`, `KEYCLOAK_RATE_LIMIT_BURST`, réponse `429`) ; les assets de
connexion (`/resources`) ne sont pas limités. Activer et vérifier la détection de force
brute dans chaque realm pour protéger les comptes en complément.

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

Épinglées dans `vps/config/versions.env` pour les nouvelles installations. Avant toute
mise à jour d'un cluster existant, vérifier les versions réellement installées,
sauvegarder et tester la restauration et la mise à jour sur une copie isolée (voir
[`observability.md`](observability.md#notes-for-vps-upgrades)). Une réinstallation
supprime les données et sauvegardes locales.

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
