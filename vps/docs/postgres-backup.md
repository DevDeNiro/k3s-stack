# Sauvegardes PostgreSQL

Le chart `vps/postgres-backup` (installé et mis à jour par `scripts/apply-backups.sh`, appelé
par `install.sh`) crée trois CronJobs dans le namespace `storage`. Ils sauvegardent les bases
de production et celle de Keycloak sur un volume du serveur. Avec
`OFFSITE_BACKUP_REPOSITORY`, deux CronJobs de plus copient ces dumps, chiffrés, hors du
serveur (restic vers un stockage objet compatible S3) et vérifient la copie chaque semaine.

## Fonctionnement

| CronJob | Planification (fuseau du contrôleur K3s) | Rétention |
|---------|---------------------|-----------|
| `postgres-backup-daily` | tous les jours à 03:00 | 7 jours |
| `postgres-backup-weekly` | le dimanche à 04:00 | 30 jours |
| `postgres-backup-monthly` | le 1er du mois à 05:00 | 365 jours |
| `postgres-backup-offsite` (optionnel) | tous les jours à 05:30 | 7 instantanés quotidiens, 4 hebdomadaires, 12 mensuels |
| `postgres-backup-offsite-check` (optionnel) | le dimanche à 06:30 | - |

- La copie hors site est planifiée après les dumps, mais n'attend pas leur fin : vérifier
  que chaque dump attendu est terminé avant de lancer une copie manuelle.
- **Bases** : toutes les bases `*-prod` plus `keycloak` (découverte automatique,
  `databases: auto`). Les bases `*-alpha` ne sont pas sauvegardées.
- **Format** : `pg_dump -Fc --no-owner --no-acl`, compressé en gzip (`<base>_<date>.dump.gz`).
  Les rôles et leurs mots de passe ne sont pas inclus : ils sont recréés par `install.sh`
  (Keycloak) et `onboard-app.sh` (applications).
- **Image** : celle du serveur, épinglée par digest (`values/postgresql-image.yaml`), donc
  `pg_dump` a la même version que PostgreSQL.
- **Réseau** : la NetworkPolicy de PostgreSQL autorise ces jobs (label
  `app.kubernetes.io/name: postgres-backup`). Les jobs suivent le profil Pod Security
  `restricted`.
- **Échecs** : un job en échec déclenche l'alerte `KubeJobFailed` (Alertmanager), copie hors
  site comprise. Cependant, le job de dump peut réussir même si une base individuelle a
  échoué : vérifier ses journaux pour chaque base attendue et les avertissements `Failed to
  backup`. Une copie restic réussie ne prouve pas que tous les dumps sont présents.

## Emplacement des dumps

Les dumps sont écrits sur le PVC `storage/postgres-backup-pvc` (20 Gi, `local-path`),
c'est-à-dire sur le disque du serveur :

```bash
sudo ls -lR /var/lib/rancher/k3s/storage/*_storage_postgres-backup-pvc/
```

> **Attention** : `uninstall.sh` supprime ce volume avec le namespace `storage` (et
> `--k3s` ou `--all` tout le stockage du nœud). Sans copie hors site, copier les dumps
> avant une réinstallation (voir [`security-hardening.md`](security-hardening.md)).

## Copie hors site chiffrée (restic)

Le CronJob `postgres-backup-offsite` envoie le répertoire des dumps (`/backups` :
`daily/`, `weekly/`, `monthly/`) dans un dépôt restic sur un stockage objet compatible S3
(Scaleway Object Storage, par exemple). restic chiffre les données sur le serveur
(AES-256) avant l'envoi : le fournisseur ne voit que des blocs chiffrés. Chaque
exécution :

1. crée le dépôt au premier passage (`restic init`, quand restic répond « dépôt
   inexistant », code de sortie 10) ;
2. retire les verrous périmés d'une exécution interrompue (`restic unlock`) ;
3. ajoute un instantané (`restic backup`, hôte `postgres-backup`, tag `postgres-backup`) ;
4. applique la rétention : `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune`.

Le dimanche, `postgres-backup-offsite-check` vérifie la structure du dépôt et relit 10 % des
données (`restic check --read-data-subset=10%`). Les jobs tournent en utilisateur non root
(UID 1001), système de fichiers racine en lecture seule, volume des dumps monté en lecture
seule et cache restic dans un `emptyDir`. Image : `docker.io/restic/restic`, version
`RESTIC_VERSION` de `config/versions.env`.

Le dépôt ne contient que les dumps PostgreSQL. **Copier à la main hors du serveur la
sauvegarde chiffrée de la clé Sealed Secrets** (`/var/backups/k3s-stack/sealed-secrets/`,
`export-secrets.sh backup-sealing-key`) : elle permet de déchiffrer les SealedSecrets
existants après restauration. Sauvegarder aussi les clés applicatives pour pouvoir les
sceller à nouveau si nécessaire.

### Configurer

1. Chez le fournisseur : un bucket dédié (région proche du serveur, versioning ou
   verrouillage d'objets recommandé) et une paire de clés limitée à ce bucket (lecture,
   écriture, suppression : `forget --prune` supprime les anciens blocs).
2. Dans `vps/config.env` :

   ```bash
   OFFSITE_BACKUP_REPOSITORY="s3:https://s3.fr-par.scw.cloud/my-bucket/k3s-stack"
   OFFSITE_BACKUP_REGION="fr-par"
   ```

3. Les identifiants, saisis sans écho (jamais en argument), puis le chart :

   ```bash
   sudo ./vps/scripts/setup-secrets.sh set-offsite-backup
   sudo ./vps/scripts/apply-backups.sh
   ```

`set-offsite-backup` enregistre `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` et
`RESTIC_PASSWORD` dans le Secret `storage/postgres-backup-offsite` et dans
`/root/.k3s-secrets/offsite-backup.env`. Un mot de passe laissé vide (sans valeur
enregistrée) est généré : le noter aussitôt dans un gestionnaire de mots de passe
(`sudo ./vps/scripts/export-secrets.sh show offsite-backup`). **Sans `RESTIC_PASSWORD`, la
copie hors site est définitivement illisible.** Pour un dépôt existant (réinstallation),
saisir son mot de passe : un autre mot de passe échoue (code de sortie 12). Pour en
changer : `restic key passwd`, puis `set-offsite-backup`.

Vider `OFFSITE_BACKUP_REPOSITORY` puis relancer `apply-backups.sh` retire les CronJobs hors
site ; le dépôt et ses instantanés restent dans le bucket.

### Lancer une copie maintenant

```bash
JOB="offsite-manual-$(date +%s)"
kubectl create job --from=cronjob/postgres-backup-offsite "$JOB" -n storage
kubectl wait --for=condition=complete "job/$JOB" -n storage --timeout=15m
kubectl logs -n storage "job/$JOB"
# vérification du dépôt
JOB="offsite-check-$(date +%s)"
kubectl create job --from=cronjob/postgres-backup-offsite-check "$JOB" -n storage
kubectl wait --for=condition=complete "job/$JOB" -n storage --timeout=15m
kubectl logs -n storage "job/$JOB"
```

Le journal se termine par la liste des instantanés et `[INFO] Off-site copy completed`.

## Copier les dumps hors du serveur à la main

Sans copie hors site, depuis le poste :

```bash
ssh <user>@<vps> 'sudo sh -c "tar -C /var/lib/rancher/k3s/storage -czf - *_storage_postgres-backup-pvc"' \
    > postgres-backups-$(date +%Y%m%d).tar.gz
```

Les dumps contiennent les données en clair : les conserver chiffrés.

## Commandes utiles

```bash
# CronJobs et derniers jobs
kubectl get cronjobs,jobs -n storage

# Sauvegarde immédiate et suivi
JOB="manual-backup-$(date +%s)"
kubectl create job --from=cronjob/postgres-backup-daily "$JOB" -n storage
kubectl wait --for=condition=complete "job/$JOB" -n storage --timeout=15m
kubectl logs -n storage "job/$JOB"
```

## Restaurer une base

Sur le serveur, en root. Le mot de passe administrateur passe par stdin, jamais en
argument de commande. Les objets restaurés appartiennent au rôle de la base.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DB=my-app-prod
DUMP=/var/lib/rancher/k3s/storage/<volume>/daily/${DB}_<date>.dump.gz
PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)

gunzip -t "$DUMP" && { printf '%s\n' "$PGPW"; gunzip -c "$DUMP"; } \
    | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
        'IFS= read -r PGPASSWORD; export PGPASSWORD
         pg_restore -h 127.0.0.1 -U postgres -d "$1" --no-owner --role="$1" --clean --if-exists --exit-on-error' restore "$DB"
```

- La base et le rôle doivent exister (`onboard-app.sh`, ou `install.sh` pour `keycloak`).
- Arrêter l'application pendant la restauration
  (`kubectl scale deploy --all -n <namespace> --replicas=0`). Si l'auto-sync d'Argo CD
  est actif, prévoir une suspension compatible avec l'ApplicationSet et vérifier que les
  pods restent arrêtés : modifier seulement l'Application générée peut être annulé. Pour Keycloak :
  `kubectl scale statefulset keycloak -n security --replicas=0`, puis `--replicas=1`.
- Un dump d'une version plus ancienne de PostgreSQL se restaure sans conversion.

### Depuis la copie hors site

Quand les dumps locaux sont perdus (serveur réinstallé ou détruit). Sur le serveur, en
root, ou sur un poste disposant de restic 0.14 ou plus récent (`apt install restic`, ou
l'image `docker.io/restic/restic`) :

```bash
export RESTIC_REPOSITORY='s3:https://s3.fr-par.scw.cloud/my-bucket/k3s-stack'   # OFFSITE_BACKUP_REPOSITORY
export AWS_DEFAULT_REGION=fr-par                                              # OFFSITE_BACKUP_REGION
# Identifiants depuis le Secret, quand le cluster tourne :
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD; do
    export "$key=$(kubectl get secret postgres-backup-offsite -n storage -o "jsonpath={.data.$key}" | base64 -d)"
done
# ... sinon depuis le gestionnaire de mots de passe, saisis sans écho (idem pour les deux clés) :
#   read -r -s -p "RESTIC_PASSWORD: " RESTIC_PASSWORD; echo; export RESTIC_PASSWORD

restic snapshots --tag postgres-backup                 # instantanés disponibles
restic ls latest /backups/daily                        # dumps du dernier instantané
restic restore latest --target /var/backups/k3s-stack/restore --include /backups/daily
```

Un instantané plus ancien se restaure avec son identifiant à la place de `latest`
(`restic snapshots` les liste). Les fichiers arrivent dans
`/var/backups/k3s-stack/restore/backups/daily/` : restaurer ensuite la base avec
`pg_restore` comme ci-dessus (`DUMP=/var/backups/k3s-stack/restore/backups/daily/<base>_<date>.dump.gz`),
après avoir recréé le rôle et la base (`install.sh`, `onboard-app.sh` avec les mots de passe
d'origine). Pour Keycloak, l'arrêter et restaurer dans une base `keycloak` vide appartenant
au rôle `keycloak`, puis le redémarrer. Recréer la base efface ses données : préparer et
tester la procédure sur une copie isolée avant toute opération réelle. Puis effacer les traces :

```bash
rm -rf /var/backups/k3s-stack/restore      # dumps en clair
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
```

## Exercice de restauration

Une sauvegarde n'est fiable qu'une fois restaurée. Avant la mise en production d'une
application, tester la restauration sur un cluster isolé, puis la renouveler chaque
trimestre et après toute modification des sauvegardes.

La procédure ci-dessous restaure le dernier dump hors site dans une base temporaire sur
le serveur de production. Elle ne modifie pas la base de production, mais partage ses
ressources et ne remplace pas un exercice sur un cluster isolé. Sur le serveur, en root
(environ 15 minutes) :

1. Copie hors site fraîche : lancer `postgres-backup-offsite` (voir « Lancer une copie
   maintenant ») et attendre `[INFO] Off-site copy completed`.
2. Restaurer les dumps depuis restic (« Depuis la copie hors site »), puis choisir le dump
   à tester :

   ```bash
   DB=my-app-prod
   DUMP=$(ls -1 /var/backups/k3s-stack/restore/backups/daily/${DB}_*.dump.gz | tail -1)
   ```

3. Le restaurer dans une base temporaire et comparer quelques comptages avec la base de
   production :

   ```bash
   PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)
   pg() {
       printf '%s\n' "$PGPW" | kubectl exec -i -n storage postgresql-0 -c postgresql -- \
           sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec "$@"' sh "$@"
   }
   pg psql -h 127.0.0.1 -U postgres -d postgres -X -c 'CREATE DATABASE restore_drill'
   { printf '%s\n' "$PGPW"; gunzip -c "$DUMP"; } \
       | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
           'IFS= read -r PGPASSWORD; export PGPASSWORD
            pg_restore -h 127.0.0.1 -U postgres -d restore_drill --no-owner --no-acl --exit-on-error'
   for db in restore_drill "$DB"; do
       pg psql -h 127.0.0.1 -U postgres -d "$db" -X -A -t -c \
           "SELECT current_database(), count(*) FROM pg_stat_user_tables"
   done
   ```

   Compléter par le comptage des lignes de quelques tables métier (`SELECT count(*) FROM
   <table>`) dans les deux bases : les écarts doivent correspondre à l'activité depuis le
   dump.
4. Nettoyer et consigner l'exercice (date, instantané, durée, résultat) :

   ```bash
   pg psql -h 127.0.0.1 -U postgres -d postgres -X -c 'DROP DATABASE restore_drill'
   rm -rf /var/backups/k3s-stack/restore
   unset PGPW AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
   ```

Vérifier aussi, au moins une fois par an, que la clé Sealed Secrets sauvegardée hors du
serveur se déchiffre avec sa passphrase (`openssl enc -d ...`, voir
`export-secrets.sh restore-sealing-key`) et que le mot de passe restic du gestionnaire de
mots de passe ouvre le dépôt depuis un poste (`restic snapshots`).

## Configuration

`vps/postgres-backup/values.yaml` :

| Clé | Effet |
|-----|-------|
| `schedules.<daily\|weekly\|monthly>` | `enabled`, `cron`, `retentionDays` |
| `databases` | `auto`, ou une liste explicite de bases |
| `infrastructureDatabases` | bases toujours incluses (`keycloak`) |
| `localStorage.storageSize` | taille du PVC |
| `resources` | ressources des jobs |
| `offsite.backup` | `cron`, rétention `keepDaily`, `keepWeekly`, `keepMonthly` |
| `offsite.check` | `cron`, `readDataSubset` (part des données relue, vide : structure seule) |
| `offsite.resources`, `offsite.activeDeadlineSeconds` | ressources et durée maximale des jobs restic |

`offsite.enabled`, `offsite.repository`, `offsite.region` et `offsite.image.tag` viennent
de `config.env` et de `config/versions.env` (`templates/postgres-backup/offsite-values.yaml.tpl`).

Appliquer une modification (le script ajoute l'image du serveur et les réglages hors site) :

```bash
sudo ./vps/scripts/apply-backups.sh
./vps/scripts/apply-backups.sh --dry-run    # rendu des manifestes, sans root
```
