# Sécurité de la plateforme

Ce document décrit les mesures de sécurité appliquées par les scripts et leurs limites
connues. La procédure de migration de l'ancienne plateforme est conservée dans les
archives.

## Mesures en place

### Hôte

| Mesure | Détail | Fichier |
|--------|--------|---------|
| Pare-feu UFW | entrées refusées par défaut ; SSH limité en débit ; 80/443 ouverts ; réseaux pods/services de K3s autorisés, y compris le trafic routé des pods | `scripts/harden-host.sh` |
| API Kubernetes fermée | toute règle 6443 existante est supprimée ; accès par tunnel SSH (`setup-remote.sh`), ou `--allow-api-from <cidr>` explicite | `scripts/harden-host.sh` |
| Même backend iptables | `iptables` est installé avant K3s : K3s, flannel et UFW écrivent dans les mêmes tables (sinon le `DROP` d'UFW coupe le DNS et l'accès Internet des pods) | `install.sh` |
| Mises à jour de sécurité automatiques | `unattended-upgrades`, sans redémarrage automatique | `config/apt/20auto-upgrades` |
| SSH par clé uniquement (option) | refusé s'il n'existe aucune clé autorisée ; configuration validée par `sshd -t` | `config/ssh/10-k3s-stack-hardening.conf` |

### K3s

| Mesure | Détail | Fichier |
|--------|--------|---------|
| Flags dans un fichier | `/etc/rancher/k3s/config.yaml` : jamais perdus lors des mises à jour (l'installeur K3s est lancé sans argument) | `config/k3s/config.yaml` |
| Secrets chiffrés au repos | `secrets-encryption` (XSalsa20-Poly1305) dès le premier démarrage | `config/k3s/config.yaml` |
| Journal d'audit | Secrets et ConfigMaps au niveau metadata, `pods/exec` au niveau requête ; 7 jours, 3 × 50 Mo | `config/k3s/audit-policy.yaml` |
| kubeconfig administrateur | mode 0600 | `config/k3s/config.yaml` |
| Traefik et servicelb désactivés | NGINX Gateway Fabric est le seul point d'entrée | `config/k3s/config.yaml` |
| Mises à jour encadrées | sauvegarde à froid puis montée d'une version mineure à la fois | `scripts/k3s-maintenance.sh` |

### Admission et réseau

- **Pod Security Admission** par namespace : `baseline` pour l'infrastructure ;
  `privileged` seulement pour `nginx-gateway` (hostPorts 80/443) et `monitoring`
  (node-exporter, Alloy), avec audit et avertissements au niveau `baseline`. Côté
  applications : `restricted` en alpha comme en prod (`config/onboarding/`) : l'alpha suit
  `develop` automatiquement et partage le nœud avec la prod (`baseline` laisserait la
  capacité NET_RAW aux conteneurs root).
- **NetworkPolicies** (`manifests/network-policies.yaml`) :
  - PostgreSQL est joignable uniquement depuis Keycloak, les namespaces applicatifs
    (label `app.kubernetes.io/managed-by=k3s-stack`) et les CronJobs de sauvegarde ;
  - Keycloak est restreint de la même façon ; il ne sort que vers PostgreSQL, le DNS, le
    HTTPS (fournisseurs d'identité OIDC) et le SMTP 587/465 (emails du realm via un
    relais), ces deux derniers vers les adresses publiques uniquement ;
  - chaque namespace applicative reçoit à l'onboarding la policy
    `k3s-stack-default-ingress` : seuls ses propres pods, la passerelle et Prometheus
    ouvrent des connexions vers ses pods ;
  - `monitoring` et `argocd` n'acceptent que leurs propres pods : Loki répond sans
    authentification sur les journaux de toutes les namespaces, Alertmanager accepte des
    silences, et les composants internes d'Argo CD n'ont pas à être joints par les
    applications. Grafana et le serveur Argo CD restent accessibles par port-forward
    uniquement.
  - La NetworkPolicy du chart PostgreSQL est désactivée : elle ouvrait le port 5432 à
    tous les pods du cluster, et les règles s'additionnent.
- **Quotas et limites par défaut** dans chaque namespace applicatif.

### Cloisonnement des applications

Une application est une frontière de confiance : quiconque peut pousser sur sa branche
`develop` contrôle ce que ses namespaces exécutent. Rien de ce qu'il pousse ne doit
atteindre une autre application ni la plateforme.

| Mesure | Détail | Fichier |
|--------|--------|---------|
| AppProject par application | sources : son seul dépôt ; destinations : `<app>-alpha` et `<app>-prod` (Argo CD vérifie la namespace de chaque ressource) ; aucune ressource de niveau cluster ; `ResourceQuota`, `LimitRange`, `Endpoints` et `EndpointSlice` refusés (un Service ferait suivre la passerelle vers les pods d'une autre namespace) | `templates/onboarding/appproject.yaml.tpl` |
| Pas d'onboarding, pas de déploiement | Argo CD ne crée ni namespace (plus de `CreateNamespace`) ni projet : un dépôt non onboardé n'a pas d'Application ; le projet `default` est vidé | `templates/argocd/applicationsets.yaml.tpl`, `manifests/argocd-default-project.yaml` |
| Propriétaire de chaque hostname | le listener HTTPS d'un hostname n'accepte que les routes des namespaces déclarées dans `GATEWAY_HOSTNAMES` (`<hostname>=<namespace>`, étiquette `kubernetes.io/metadata.name` posée par l'API) ; le listener HTTP ne sert que la redirection et les défis ACME (`Same`) | `templates/gateway/` |
| Deux jetons | le jeton des dépôts reste dans `argocd` ; le jeton copié dans les namespaces applicatives est en lecture des images seulement (`read:packages`) | `scripts/export-secrets.sh` |
| Pas de service partagé sans cloisonnement | PostgreSQL (rôles, bases fermées aux autres rôles) et Keycloak (realms) sont partagés ; un cache Redis vit dans le chart de l'application | `sql/ensure-role-database.sql` |
| Aucun jeton de cluster distribué | l'option `--with-cicd` (compte de service administrateur de la namespace, jeton sans expiration) est supprimée : Argo CD tire les déploiements | `scripts/onboard-app.sh` |

### Secrets

- Mots de passe générés (24 à 32 caractères), conservés dans `/root/.k3s-secrets`
  (0700, fichiers en 0600).
- **Jamais en argument de commande.** Les valeurs passent par stdin (`kubectl exec`,
  `htpasswd -i`) ou par descripteur de fichier (`kubectl create secret --from-env-file`).
  Le journal d'audit a été vérifié : aucune valeur générée n'y apparaît.
- Rendu des templates dans un sous-shell : les valeurs ne sont jamais exportées au reste
  du script.
- Clé Sealed Secrets sauvegardée chiffrée (AES-256-CBC, PBKDF2 600 000 itérations) dans
  `/var/backups/k3s-stack/sealed-secrets/`. **Copier chaque sauvegarde hors du serveur.**
- Identifiants saisis par l'opérateur (token des dépôts, webhook Discord, clés du stockage
  objet et mot de passe restic) : lus sans écho, jamais en argument. Le mot de passe restic
  se range aussi dans un gestionnaire de mots de passe (`export-secrets.sh show
  offsite-backup`) : sans lui, la copie hors site est indéchiffrable.

### PostgreSQL

| Mesure | Détail |
|--------|--------|
| Authentification SCRAM | `pg_hba` explicite (`scram-sha-256` partout) ; rôles stockés en SCRAM |
| TLS effectif | sans `pg_hba` explicite, l'image Bitnami exige un certificat client en TLS et les clients retombent en clair ; `ssl_groups` est adapté à l'OpenSSL de l'image (sinon PostgreSQL 18 refuse de démarrer) |
| Clients en TLS | Keycloak en `sslmode=require` ; les URLs `url` et `r2dbc-url` des Secrets `<app>-db` exigent TLS |
| Rôle et base dédiés par application | aucun mot de passe existant n'est modifié sans être connu |
| Bases fermées aux autres rôles | `REVOKE ALL ON DATABASE ... FROM PUBLIC` : PostgreSQL accorde `CONNECT` et `TEMPORARY` à tous les rôles par défaut ; seul le propriétaire se connecte (le superutilisateur n'est pas concerné) |
| Image épinglée par digest | `values/postgresql-image.yaml` : un re-pull ne peut pas changer de version majeure ; les sauvegardes utilisent la même image |

### Exposition publique

- HTTPS sur chaque hostname (un certificat Let's Encrypt par hostname), redirection HTTP
  vers HTTPS.
- Keycloak : seuls `/realms` et `/resources` sont routés. Le realm `master` est répondu
  par la gateway sans atteindre Keycloak (vérifié avec `%6Daster`, `//`, `..` et
  `%2e%2e`), et la console d'administration n'est pas routée.
- Limite de débit par adresse cliente sur les endpoints OIDC de Keycloak (RateLimitPolicy
  `keycloak` de NGINX Gateway Fabric, `limit_req` : `KEYCLOAK_RATE_LIMIT_RATE` par défaut
  `10r/s`, rafale `KEYCLOAK_RATE_LIMIT_BURST` de `20`, puis réponses `429`). Les assets de
  connexion (`/resources`, HTTPRoute `keycloak-resources`) ne sont pas limités : une page de
  connexion ne coûte qu'une ou deux requêtes limitées. Activer et vérifier la détection de
  force brute dans chaque realm. Les applications posent leur propre RateLimitPolicy sur
  leurs chemins sensibles.
- Grafana, Prometheus, Alertmanager et Argo CD ne sont accessibles que par
  `kubectl port-forward`.

### Journaux d'accès (minimisation)

Les URLs peuvent porter des secrets : jetons d'opposition `/stop/<jeton>`, codes et `state`
OAuth, `id_token_hint` de déconnexion.

| Niveau | Mesure | Fichier |
|--------|--------|---------|
| Passerelle | journal d'accès JSON (NginxProxy de NGF) : chemin `$uri` sans query string, sans Referer (il porte l'URL complète de la page précédente) | `values/nginx-gateway-fabric.yaml` |
| Loki | étapes `replace` d'Alloy : le jeton des chemins `/stop/<jeton>` et les valeurs `code`, `state`, `session_state`, `id_token_hint` des query strings sont remplacés par `<redacted>`, quel que soit le pod | `values/alloy.yaml` |

Ce qui reste : les fichiers du nœud (`/var/log/pods/`, root uniquement, lus par
`kubectl logs`) gardent les lignes brutes jusqu'à leur rotation par le kubelet (10 Mio par
fichier, 5 fichiers par conteneur avec les réglages par défaut de K3s) ou la suppression du
pod. Pour la passerelle, ce sont les chemins `/stop/<jeton>` (jamais les query strings) ;
pour les applications, ce qu'elles journalisent elles-mêmes : ne pas journaliser d'URL
complète côté application. Loki conserve 7 jours de journaux déjà masqués.

### Chaîne d'approvisionnement

- Toutes les versions sont épinglées (`config/versions.env`), validées ensemble par
  `helm template --kube-version`.
- Les CRDs Gateway API sont fournies et mises à jour par K3s : aucun manifest distant
  n'est appliqué à l'installation.

## Limites connues

- **Copie hors site partielle** : la copie chiffrée restic (optionnelle,
  `OFFSITE_BACKUP_REPOSITORY`, voir [`postgres-backup.md`](postgres-backup.md)) ne couvre
  que les dumps PostgreSQL. La sauvegarde de la clé Sealed Secrets et celles de K3s se
  copient hors du serveur à la main. Les clés du stockage objet rangées sur le serveur
  peuvent aussi supprimer le dépôt : activer le versioning ou le verrouillage d'objets du
  bucket chez le fournisseur.
- Les images d'extension Keycloak (`KEYCLOAK_EXTENSION_IMAGES`) exécutent leurs providers
  avec tous les droits de Keycloak (base, identifiants) : n'utiliser que des images de
  confiance, référencées par un tag immuable ou un digest.
- PostgreSQL accepte encore les connexions en clair des clients qui ne demandent pas TLS
  (R2DBC est en `sslMode=disable` par défaut) : ajouter `sslMode=require` côté
  application. Il sera ensuite possible d'exiger TLS côté serveur.
- Keycloak tourne avec `--hostname-strict=false` : fixer `KC_HOSTNAME` sur le hostname
  public.
- L'image PostgreSQL Bitnami n'est publiée qu'en `latest` : le digest épinglé doit être
  mis à jour délibérément (commentaire de `values/postgresql-image.yaml`).
- Keycloak (port 8080, API d'administration comprise) reste joignable depuis les
  namespaces applicatives : une application gère les utilisateurs de son realm avec un
  compte de service de ce realm. Aucune application ne doit détenir d'identifiant du realm
  `master`, qui administre tous les realms. Vérifier un mot de passe long, la détection
  de force brute du realm `master` (Realm settings > Security defenses) et l'OTP pour son
  administrateur : depuis les pods, ses endpoints ne passent pas par la limite de débit
  de la passerelle.
- Un seul jeton de lecture des images sert toutes les organisations : si elles
  correspondent à des clients distincts, utiliser un compte machine par organisation.
- Les applications sortent librement vers Internet et vers les services de la plateforme
  autorisés : le cloisonnement repose sur les politiques d'entrée.
- Promtail est en fin de vie : les installations existantes doivent suivre la procédure
  de migration vers Alloy dans [`observability.md`](observability.md#notes-for-vps-upgrades).
- Les mises à jour d'une installation existante exigent une procédure adaptée et testée
  (par exemple, la taille du PVC d'Alertmanager est immuable). Une réinstallation
  supprime les données et les sauvegardes locales : ne pas l'utiliser comme mise à jour
  sans sauvegarde et restauration vérifiées.

## Migration historique

La procédure de migration de l’ancienne plateforme est conservée dans les [archives](archive/migration-ancienne-plateforme.md) ; elle ne constitue pas une procédure de mise à jour du cluster actuel.
