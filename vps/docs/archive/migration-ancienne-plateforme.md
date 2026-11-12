# Migration historique de l’ancienne plateforme

> Archive historique : cette procédure décrit une ancienne installation et comporte des opérations destructives. Ne pas l’utiliser telle quelle pour le cluster actuel.

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
par `onboard-app.sh`. Exemple pour `my-app` :

```text
MY_APP_ALPHA_DB_PASSWORD=...
MY_APP_PROD_DB_PASSWORD=...
```

Conserver aussi les identifiants de l'ancienne installation : `uninstall.sh` supprime
`/root/.k3s-secrets`, qui contient notamment le token d'accès aux dépôts (étape 12).

```bash
install -d -m 700 /var/backups/k3s-stack/migration
cp -a /root/.k3s-secrets /var/backups/k3s-stack/migration/k3s-secrets-old
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
nano vps/config.env           # GATEWAY_HOSTNAMES (<hostname>=<namespace>), AUTH_HOSTNAMES, SCM_*, REGISTRY_HOST, LETSENCRYPT_EMAIL, OFFSITE_BACKUP_*
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

Les objets restaurés appartiennent au rôle de la base (`--no-owner --role`). Keycloak a
créé son propre schéma à l'installation : sa base est recréée vide avant la restauration
(sinon les tables de la nouvelle version bloquent `--clean` et le schéma restauré est
incohérent). Keycloak est arrêté pendant l'opération ; il migre ensuite son schéma et
ses realms au démarrage.

```bash
PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)
pg() {
    printf '%s\n' "$PGPW" | kubectl exec -i -n storage postgresql-0 -c postgresql -- \
        sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec "$@"' sh "$@"
}
restore() {
    { printf '%s\n' "$PGPW"; cat "/var/backups/k3s-stack/migration/$1.dump"; } \
        | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
            'IFS= read -r PGPASSWORD; export PGPASSWORD
             pg_restore -h 127.0.0.1 -U postgres -d "$1" --no-owner --role="$1" --clean --if-exists' restore "$1"
}
kubectl scale statefulset keycloak -n security --replicas=0
kubectl wait --for=delete pod/keycloak-0 -n security --timeout=180s
pg psql -h 127.0.0.1 -U postgres -d postgres -X \
    -c 'DROP DATABASE keycloak WITH (FORCE)' -c 'CREATE DATABASE keycloak OWNER keycloak' \
    -c 'REVOKE ALL ON DATABASE keycloak FROM PUBLIC'
restore keycloak
kubectl scale statefulset keycloak -n security --replicas=1
restore <app>-prod
restore <app>-alpha
```

Lire les éventuels avertissements de `pg_restore` (extensions, objets déjà présents).

Le compte `admin` du realm `master` redevient celui de l'ancienne installation : son mot de
passe est `KEYCLOAK_ADMIN_PASSWORD` de `migration/k3s-secrets-old/credentials.env` (celui de
`/root/.k3s-secrets/credentials.env` ne vaut que pour une base vide). Le reporter dans
`credentials.env`, ou le changer dans la console d'administration (port-forward) et y
enregistrer le nouveau. Ce compte administre tous les realms : aucune application ne doit
le détenir (une application gère son realm avec un compte de service de ce realm). Si une
application l'utilisait, passer à un compte de service, puis changer ce mot de passe.

### 12. Redonner accès aux dépôts

Argo CD découvre alors les dépôts de chaque organisation de `SCM_ORGANIZATIONS` et
déploie les applications onboardées. Deux jetons : lecture des images (`read:packages`
seul, copié dans chaque namespace applicative), puis dépôts (`repo`, namespace `argocd`
seulement), idéalement d'un compte machine en lecture seule :

```bash
./vps/scripts/export-secrets.sh set-registry-credentials
./vps/scripts/export-secrets.sh set-scm-credentials github
kubectl get appprojects,applications -n argocd
kubectl get sealedsecrets -A
```

Puis les identifiants de la copie hors site (le mot de passe restic du dépôt existant,
depuis le gestionnaire de mots de passe) : `./vps/scripts/setup-secrets.sh
set-offsite-backup`.

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

- `config.env` : `DOMAIN` est remplacé par `GATEWAY_HOSTNAMES` et `AUTH_HOSTNAMES` ;
  `SCM_ORGANIZATIONS` (plusieurs organisations) et `REGISTRY_HOST` complètent
  `SCM_ORGANIZATION` et `REGISTRY_BASE`, toujours lus pour une organisation unique.
- Chaque entrée de `GATEWAY_HOSTNAMES` déclare la namespace qui route le hostname
  (`<hostname>=<namespace>`) ; l'ancien format est refusé avec un message explicite.
- Deux jetons au lieu d'un (`set-registry-credentials`, `set-scm-credentials`).
- Argo CD ne déploie que les applications onboardées (un AppProject chacune) ; le niveau
  Pod Security de l'alpha passe à `restricted`.
- Plus de Redis partagé (namespace `database`) : un cache vit dans le chart de
  l'application. `onboard-app.sh --with-cicd` et `export-secrets.sh export-kubeconfig`
  sont supprimés.
- Migration en place d'un VPS déjà à jour par ailleurs :
  [procédure historique](migrations-en-place-historiques.md#isolating-the-applications-on-an-existing-vps).
- kubectl depuis le poste passe par un tunnel SSH (le port 6443 est fermé).
- Grafana est servi à la racine (plus de sous-chemin `/grafana`).
- Le webhook Discord utilise l'intégration native d'Alertmanager : URL sans `/slack`.
  Les alertes ne partaient pas avec l'ancienne configuration (clé ignorée par le chart).
- Les CronJobs de sauvegarde n'étaient pas autorisés par les NetworkPolicies : vérifier
  les sauvegardes de l'ancienne installation avant de s'y fier.
- Versions : K3s 1.37.2, PostgreSQL 18.6, Keycloak 26.8.2, NGINX Gateway Fabric 2.8.1,
  cert-manager 1.21.3.
