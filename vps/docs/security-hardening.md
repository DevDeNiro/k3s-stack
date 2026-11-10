# Sécurité de la plateforme et migration du VPS existant

Ce document décrit les mesures de sécurité appliquées par les scripts, leurs limites
connues, et la procédure pour faire passer le VPS actuel sur la nouvelle plateforme
(réinstallation complète, données et secrets conservés).

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
  (node-exporter, Promtail), avec audit et avertissements au niveau `baseline`. Côté
  applications : `baseline` en alpha, `restricted` en prod (`config/onboarding/`).
- **NetworkPolicies** (`manifests/network-policies.yaml`) :
  - PostgreSQL est joignable uniquement depuis Keycloak, les namespaces applicatifs
    (label `app.kubernetes.io/managed-by=k3s-stack`) et les CronJobs de sauvegarde ;
  - Redis et Keycloak sont restreints de la même façon ;
  - Grafana et le serveur Argo CD n'acceptent aucune connexion entrante (accès par
    port-forward uniquement).
  - La NetworkPolicy du chart PostgreSQL est désactivée : elle ouvrait le port 5432 à
    tous les pods du cluster, et les règles s'additionnent.
- **Quotas et limites par défaut** dans chaque namespace applicatif.

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

### PostgreSQL

| Mesure | Détail |
|--------|--------|
| Authentification SCRAM | `pg_hba` explicite (`scram-sha-256` partout) ; rôles stockés en SCRAM |
| TLS effectif | sans `pg_hba` explicite, l'image Bitnami exige un certificat client en TLS et les clients retombent en clair ; `ssl_groups` est adapté à l'OpenSSL de l'image (sinon PostgreSQL 18 refuse de démarrer) |
| Clients en TLS | Keycloak en `sslmode=require` ; les URLs `url` et `r2dbc-url` des Secrets `<app>-db` exigent TLS |
| Rôle et base dédiés par application | aucun mot de passe existant n'est modifié sans être connu |
| Image épinglée par digest | `values/postgresql-image.yaml` : un re-pull ne peut pas changer de version majeure ; les sauvegardes utilisent la même image |

### Exposition publique

- HTTPS sur chaque hostname (un certificat Let's Encrypt par hostname), redirection HTTP
  vers HTTPS.
- Keycloak : seuls `/realms` et `/resources` sont routés. Le realm `master` est répondu
  par la gateway sans atteindre Keycloak (vérifié avec `%6Daster`, `//`, `..` et
  `%2e%2e`), et la console d'administration n'est pas routée.
- Grafana, Prometheus, Alertmanager et Argo CD ne sont accessibles que par
  `kubectl port-forward`.

### Chaîne d'approvisionnement

- Toutes les versions sont épinglées (`config/versions.env`), validées ensemble par
  `helm template --kube-version`.
- Les CRDs Gateway API sont fournies et mises à jour par K3s : aucun manifest distant
  n'est appliqué à l'installation.

## Limites connues

- **Pas de sauvegarde hors site automatique** : les dumps PostgreSQL et les sauvegardes
  K3s restent sur le serveur (prévu plus tard).
- PostgreSQL accepte encore les connexions en clair des clients qui ne demandent pas TLS
  (R2DBC est en `sslMode=disable` par défaut) : ajouter `sslMode=require` côté
  application. Il sera ensuite possible d'exiger TLS côté serveur.
- Keycloak tourne avec `--hostname-strict=false` : fixer `KC_HOSTNAME` sur le hostname
  public.
- L'image PostgreSQL Bitnami n'est publiée qu'en `latest` : le digest épinglé doit être
  mis à jour délibérément (commentaire de `values/postgresql-image.yaml`).
- Promtail est en fin de vie : migration vers Grafana Alloy à prévoir.
- Les mises à jour en place d'une installation existante ne sont pas le chemin nominal
  (par exemple, la taille du PVC d'Alertmanager est immuable) : réinstaller.

## Migrer le VPS existant

L'ancienne installation (flags K3s passés à l'installeur, API 6443 ouverte, etc.) ne se
met pas à jour en place : on la sauvegarde, on la désinstalle, puis on réinstalle.
Prévoir une coupure des applications d'environ 45 minutes.

Pré-requis : ces modifications poussées sur le dépôt, la passphrase de la clé Sealed
Secrets choisie et rangée dans un gestionnaire de mots de passe, et la liste des
hostnames publics actuels.

### 1. Mettre à jour le dépôt sur le VPS

```bash
ssh <user>@<vps>
sudo -i
cd <chemin-du-clone>/k3s-stack && git pull
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### 2. Sauvegarder la clé Sealed Secrets

```bash
./vps/scripts/export-secrets.sh backup-sealing-key
ls -l /var/backups/k3s-stack/sealed-secrets/
```

### 3. Relever les mots de passe des bases applicatives

Les SealedSecrets des applications (dans Git) contiennent ces mots de passe : les rôles
recréés doivent avoir les mêmes. Pour chaque application et environnement :

```bash
kubectl get secrets -n <app>-<env>
./vps/scripts/export-secrets.sh fetch-from-k8s <secret-de-la-base> <app>-<env>
```

Les écrire dans `/var/backups/k3s-stack/migration/<app>.env` (mode 0600), au format lu
par `onboard-app.sh`. Exemple pour `coterie-webapp` :

```text
COTERIE_WEBAPP_ALPHA_DB_PASSWORD=...
COTERIE_WEBAPP_PROD_DB_PASSWORD=...
```

### 4. Exporter les bases

Le mot de passe administrateur transite par stdin, les dumps arrivent sur l'hôte.

```bash
install -d -m 700 /var/backups/k3s-stack/migration
PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)
pg() {
    printf '%s\n' "$PGPW" | kubectl exec -i -n storage postgresql-0 -c postgresql -- \
        sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec "$@"' sh "$@"
}
DBS=$(pg psql -h 127.0.0.1 -U postgres -d postgres -X -A -t \
    -c "select datname from pg_database where not datistemplate and datname <> 'postgres'")
for db in $DBS; do
    pg pg_dump -h 127.0.0.1 -U postgres -Fc --no-owner --no-acl "$db" \
        > "/var/backups/k3s-stack/migration/$db.dump"
done
ls -l /var/backups/k3s-stack/migration/
```

Si le Secret porte un autre nom sur l'ancienne installation, le retrouver avec
`kubectl get secrets -n storage`.

### 5. Copier les sauvegardes hors du serveur (depuis le poste)

```bash
ssh <user>@<vps> 'sudo tar -C /var/backups/k3s-stack -czf - migration sealed-secrets' \
    > vps-migration-$(date +%Y%m%d).tar.gz
```

Ces fichiers contiennent les données et les mots de passe : les stocker chiffrés.

### 6. Désinstaller l'ancienne plateforme

```bash
./vps/uninstall.sh --all
```

`/var/backups/k3s-stack` et les règles UFW sont conservés. Les volumes (données
PostgreSQL, sauvegardes locales) et `/root/.k3s-secrets` sont supprimés.

### 7. Configurer et installer

```bash
cp vps/config.env.example vps/config.env
nano vps/config.env           # GATEWAY_HOSTNAMES, AUTH_HOSTNAMES, SCM_*, REGISTRY_BASE, LETSENCRYPT_EMAIL
./vps/scripts/apply-config.sh --check
./vps/install.sh
```

`DOMAIN` n'existe plus : chaque hostname public est listé dans `GATEWAY_HOSTNAMES`.

### 8. Restaurer la clé Sealed Secrets

À faire avant de donner accès aux dépôts, pour qu'aucune application ne démarre avec des
secrets indéchiffrables :

```bash
./vps/scripts/export-secrets.sh restore-sealing-key /var/backups/k3s-stack/sealed-secrets/<fichier>.enc
```

### 9. Gateway et certificats

```bash
./vps/scripts/setup-gateway-api.sh --staging    # certificats de test : vérifier l'émission
kubectl get certificates -n nginx-gateway
./vps/scripts/setup-gateway-api.sh              # certificats de production
```

### 10. Onboarder les applications avec leurs mots de passe

```bash
install -m 600 /var/backups/k3s-stack/migration/<app>.env /root/.k3s-secrets/<app>.env
./vps/scripts/onboard-app.sh <app>
```

### 11. Restaurer les données

Les objets restaurés appartiennent au rôle de la base (`--no-owner --role`). Keycloak est
arrêté pendant sa restauration ; il migre ensuite son schéma au démarrage.

```bash
PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)
restore() {
    { printf '%s\n' "$PGPW"; cat "/var/backups/k3s-stack/migration/$1.dump"; } \
        | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
            'IFS= read -r PGPASSWORD; export PGPASSWORD
             pg_restore -h 127.0.0.1 -U postgres -d "$1" --no-owner --role="$1" --clean --if-exists' restore "$1"
}
kubectl scale statefulset keycloak -n security --replicas=0
restore keycloak
kubectl scale statefulset keycloak -n security --replicas=1
restore <app>-prod
restore <app>-alpha
```

Lire les éventuels avertissements de `pg_restore` (extensions, objets déjà présents).

### 12. Redonner accès aux dépôts

Argo CD découvre alors les dépôts et déploie les applications :

```bash
./vps/scripts/export-secrets.sh set-scm-credentials github
kubectl get applications -n argocd
kubectl get sealedsecrets -A
```

### 13. Vérifier

```bash
./vps/scripts/k3s-maintenance.sh status                 # Encryption Status: Enabled
ufw status                                              # aucune règle 6443
kubectl get pods -A | grep -v -E 'Running|Completed'    # rien
curl -s -o /dev/null -w '%{http_code}\n' https://<auth-host>/realms/master   # 500
curl -s -o /dev/null -w '%{http_code}\n' https://<auth-host>/admin/          # 404
kubectl create job --from=cronjob/postgres-backup-daily verify-backup -n storage
kubectl wait --for=condition=complete job/verify-backup -n storage --timeout=300s
grep -c -F -f <(grep '^POSTGRES_ADMIN_PASSWORD=' /root/.k3s-secrets/credentials.env | cut -d= -f2- | tr -d '"') \
    /var/log/kubernetes/audit/audit.log                 # 0
```

### 14. Finaliser

- Sur le poste : `./vps/scripts/setup-remote.sh <vps> --user <user>` (accès kubectl par
  tunnel).
- Alertes Discord : `./vps/scripts/setup-secrets.sh set-discord-webhook` (URL du webhook,
  sans `/slack`).
- Après vérification d'une connexion par clé dans une seconde session :
  `./vps/scripts/harden-host.sh --apply --harden-ssh`.
- Une fois les données vérifiées, supprimer `/var/backups/k3s-stack/migration` (dumps en
  clair) et ne garder que la copie chiffrée hors du serveur.

## Changements visibles par rapport à l'ancienne plateforme

- `config.env` : `DOMAIN` est remplacé par `GATEWAY_HOSTNAMES` et `AUTH_HOSTNAMES`.
- kubectl depuis le poste passe par un tunnel SSH (le port 6443 est fermé).
- Grafana est servi à la racine (plus de sous-chemin `/grafana`).
- Le webhook Discord utilise l'intégration native d'Alertmanager : URL sans `/slack`.
  Les alertes ne partaient pas avec l'ancienne configuration (clé ignorée par le chart).
- Les CronJobs de sauvegarde n'étaient pas autorisés par les NetworkPolicies : vérifier
  les sauvegardes de l'ancienne installation avant de s'y fier.
- Versions : K3s 1.37.2, PostgreSQL 18.6, Keycloak 26.8.2, NGINX Gateway Fabric 2.8.1,
  cert-manager 1.21.3.
