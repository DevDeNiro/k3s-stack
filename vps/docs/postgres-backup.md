# Sauvegardes PostgreSQL

Le chart `vps/postgres-backup` (installé par `install.sh`) crée trois CronJobs dans le
namespace `storage`. Ils sauvegardent les bases de production et celle de Keycloak sur
un volume du serveur. La copie hors site n'est pas encore automatisée.

## Fonctionnement

| CronJob | Planification (UTC) | Rétention |
|---------|---------------------|-----------|
| `postgres-backup-daily` | tous les jours à 03:00 | 7 jours |
| `postgres-backup-weekly` | le dimanche à 04:00 | 30 jours |
| `postgres-backup-monthly` | le 1er du mois à 05:00 | 365 jours |

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
- **Échecs** : un job en échec déclenche l'alerte `KubeJobFailed` (Alertmanager).

## Emplacement des dumps

Les dumps sont écrits sur le PVC `storage/postgres-backup-pvc` (20 Gi, `local-path`),
c'est-à-dire sur le disque du serveur :

```bash
sudo ls -lR /var/lib/rancher/k3s/storage/*_storage_postgres-backup-pvc/
```

> **Attention** : `uninstall.sh --k3s` (ou `--all`) supprime ce volume. Copier les dumps
> avant une réinstallation (voir [`security-hardening.md`](security-hardening.md)).

## Copier les dumps hors du serveur

Depuis le poste :

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
kubectl create job --from=cronjob/postgres-backup-daily manual-backup-$(date +%s) -n storage
kubectl logs -n storage -l app.kubernetes.io/name=postgres-backup --tail=50
```

## Restaurer une base

Sur le serveur, en root. Le mot de passe administrateur passe par stdin, jamais en
argument de commande. Les objets restaurés appartiennent au rôle de la base.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DB=my-app-prod
DUMP=/var/lib/rancher/k3s/storage/<volume>/daily/${DB}_<date>.dump.gz
PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)

{ printf '%s\n' "$PGPW"; gunzip -c "$DUMP"; } \
    | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
        'IFS= read -r PGPASSWORD; export PGPASSWORD
         pg_restore -h 127.0.0.1 -U postgres -d "$1" --no-owner --role="$1" --clean --if-exists' restore "$DB"
```

- La base et le rôle doivent exister (`onboard-app.sh`, ou `install.sh` pour `keycloak`).
- Arrêter l'application pendant la restauration
  (`kubectl scale deploy --all -n <namespace> --replicas=0`). Si l'auto-sync d'Argo CD
  est actif, il la redémarre à la synchronisation suivante : suspendre la synchronisation
  dans l'interface d'Argo CD le temps de l'opération. Pour Keycloak :
  `kubectl scale statefulset keycloak -n security --replicas=0`, puis `--replicas=1`.
- Un dump d'une version plus ancienne de PostgreSQL se restaure sans conversion.

## Configuration

`vps/postgres-backup/values.yaml` :

| Clé | Effet |
|-----|-------|
| `schedules.<daily\|weekly\|monthly>` | `enabled`, `cron`, `retentionDays` |
| `databases` | `auto`, ou une liste explicite de bases |
| `infrastructureDatabases` | bases toujours incluses (`keycloak`) |
| `localStorage.storageSize` | taille du PVC |
| `resources` | ressources des jobs |

Appliquer une modification :

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install postgres-backup ./vps/postgres-backup \
    -n storage -f vps/values/postgresql-image.yaml
```
