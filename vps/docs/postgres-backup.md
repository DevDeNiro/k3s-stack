# 🗄️ PostgreSQL Backup - Production

Système de backup automatisé pour les bases de données de production.

## Fonctionnalités

- **Auto-discovery** : Découvre automatiquement toutes les DBs `*-prod`
- **Infrastructure incluse** : Backup toujours `keycloak`
- **Multi-schedule** : Daily, Weekly, Monthly avec rétentions différentes
- **S3 optionnel** : Upload off-site vers S3/MinIO/Scaleway

## Schedules par défaut

| Type        | Schedule              | Rétention | Cas d'usage                              |
|-------------|-----------------------|-----------|------------------------------------------|
| **Daily**   | 03:00 UTC             | 7 jours   | Récupération rapide (erreur utilisateur) |
| **Weekly**  | Dimanche 04:00 UTC    | 30 jours  | Récupération moyen terme                 |
| **Monthly** | 1er du mois 05:00 UTC | 365 jours | Archives long terme, compliance          |

## Bases de données sauvegardées

Par défaut (`databases: auto`), le backup inclut :

```
✓ keycloak           (toujours inclus - infrastructure)
✓ myapp-prod         (auto-découvert via *-prod)
✓ another-app-prod   (auto-découvert via *-prod)
✗ myapp-alpha        (ignoré - pas en -prod)
```

## Stockage

### Local (par défaut)

Les backups sont stockés dans un PVC de 20Gi :

```
/backups/
├── daily/
│   ├── keycloak_2026-02-03_03-00-00.dump.gz
│   └── myapp-prod_2026-02-03_03-00-00.dump.gz
├── weekly/
│   └── keycloak_2026-02-02_04-00-00.dump.gz
└── monthly/
    └── keycloak_2026-02-01_05-00-00.dump.gz
```

⚠️ **Attention** : Sans S3, les backups sont sur le même VPS. Si le VPS est perdu, les backups le sont aussi.

### S3 Off-site (recommandé pour production)

Activer S3 pour une protection off-site :

```yaml
# vps/postgres-backup/values.yaml
s3:
    enabled: true
    endpoint: "https://s3.fr-par.scw.cloud"  # Scaleway
    # endpoint: "https://s3.eu-west-1.amazonaws.com"  # AWS
    bucket: "my-k3s-backups"
    region: "fr-par"
    prefix: "postgres"
    existingSecret: "s3-backup-credentials"
```

Créer le secret S3 :

```bash
kubectl create secret generic s3-backup-credentials -n storage \
    --from-literal=access-key="SCWXXXXXXXXX" \
    --from-literal=secret-key="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Commandes utiles

### Vérifier les CronJobs

```bash
kubectl get cronjobs -n storage
```

### Lancer un backup manuel

```bash
# Backup daily immédiat
kubectl create job --from=cronjob/postgres-backup-daily manual-daily -n storage

# Suivre les logs
kubectl logs -n storage job/manual-daily -f
```

### Voir les backups existants

```bash
# Accéder au PVC
kubectl exec -it -n storage deploy/postgresql -- ls -la /backups/daily/
```

### Restaurer un backup

```bash
# 1. Copier le backup localement
kubectl cp storage/postgresql-0:/backups/daily/mydb_2026-02-03.dump.gz ./mydb.dump.gz

# 2. Décompresser
gunzip mydb.dump.gz

# 3. Restaurer
kubectl exec -i -n storage postgresql-0 -- \
    env PGPASSWORD="$PASSWORD" pg_restore -U postgres -d mydb --clean --if-exists < mydb.dump
```

## Configuration

### Modifier les schedules

```yaml
# vps/postgres-backup/values.yaml
schedules:
    daily:
        enabled: true
        cron: "0 3 * * *"      # Changer l'heure
        retentionDays: 7
    weekly:
        enabled: true
        cron: "0 4 * * 0"
        retentionDays: 30
    monthly:
        enabled: false         # Désactiver si non nécessaire
```

### Spécifier les DBs manuellement

```yaml
# Au lieu de auto-discovery
databases:
    - keycloak
    - myapp-prod
    - another-app-prod
```

## Monitoring

### Vérifier le dernier backup

```bash
# Derniers jobs exécutés
kubectl get jobs -n storage -l app.kubernetes.io/name=postgres-backup --sort-by=.status.startTime

# Logs du dernier daily
kubectl logs -n storage -l app.kubernetes.io/component=backup-daily --tail=50
```

### Alerting (optionnel)

Pour être alerté en cas d'échec, configurer une alerte Prometheus :

```yaml
# Dans prometheus/rules
-   alert: PostgresBackupFailed
    expr: kube_job_failed{job_name=~"postgres-backup-.*"} > 0
    for: 1h
    labels:
        severity: critical
    annotations:
        summary: "PostgreSQL backup failed"
```

## Sécurité

- Les backups utilisent `--no-owner --no-acl` pour la portabilité
- Le format custom (`-Fc`) permet une restauration sélective
- Les credentials PostgreSQL sont lus depuis un Secret Kubernetes
- Les credentials S3 (si activé) sont également dans un Secret
