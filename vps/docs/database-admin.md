# 🗄️ Database Administration Guide

Guide complet pour administrer PostgreSQL sur le cluster K3s.

---

## Connexion à PostgreSQL

### Récupérer les credentials admin

```bash
# Mot de passe du superutilisateur postgres (sur le VPS)
sudo ./vps/scripts/export-secrets.sh show postgres

# Depuis le cluster
kubectl get secret -n storage postgresql-secret -o jsonpath='{.data.postgres-password}' | base64 -d
```

### Fonction `pgexec`

L'authentification est en SCRAM partout : une commande non interactive a besoin du mot
de passe. Le chart le monte dans le pod ; `pgexec` l'y lit, il ne quitte jamais le pod et
n'apparaît pas dans les arguments de `kubectl exec` (enregistrés par le journal d'audit).

```bash
pgexec() {
    kubectl exec -i -n storage postgresql-0 -c postgresql -- \
        sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec "$@"' sh "$@"
}
```

### Récupérer les credentials d'une application

```bash
# Remplacer <app> et <env> (alpha/prod)
APP=myapp
ENV=alpha

# Mot de passe
kubectl get secret -n ${APP}-${ENV} ${APP}-db -o jsonpath='{.data.password}' | base64 -d

# URL JDBC complète
kubectl get secret -n ${APP}-${ENV} ${APP}-db -o jsonpath='{.data.url}' | base64 -d

# Toutes les infos
kubectl get secret -n ${APP}-${ENV} ${APP}-db -o json | jq '.data | map_values(@base64d)'
```

---

## Accès interactif à PostgreSQL

### Shell psql (recommandé)

```bash
# Connexion admin
kubectl exec -it -n storage postgresql-0 -c postgresql -- \
    sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec psql -h 127.0.0.1 -U postgres'

# Connexion à une base spécifique
kubectl exec -it -n storage postgresql-0 -c postgresql -- \
    sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec psql -h 127.0.0.1 -U postgres -d myapp-alpha'
```

### Connexion avec utilisateur applicatif

psql demande le mot de passe (celui du Secret `<app>-db`, à coller) :

```bash
APP=myapp
ENV=alpha
kubectl exec -it -n storage postgresql-0 -c postgresql -- \
    psql "host=127.0.0.1 user=${APP}-${ENV} dbname=${APP}-${ENV} sslmode=require"
```

### Port-forward pour outils externes (DBeaver, pgAdmin, etc.)

```bash
kubectl port-forward -n storage svc/postgresql 5432:5432

# Puis connectez-vous à localhost:5432
# User: postgres | Password: voir "Récupérer les credentials admin"
```

---

## Commandes SQL essentielles

### Gestion des bases de données

```sql
-- Lister toutes les bases
\l

-- Créer une base
CREATE DATABASE "myapp-staging" OWNER "myapp-staging";

-- Supprimer une base (ATTENTION: irréversible!)
DROP DATABASE "myapp-staging";

-- Se connecter à une autre base
\c myapp-alpha

-- Taille des bases
SELECT datname, pg_size_pretty(pg_database_size(datname)) 
FROM pg_database ORDER BY pg_database_size(datname) DESC;
```

### Gestion des utilisateurs

```sql
-- Lister les utilisateurs
\du

-- Créer un utilisateur
CREATE USER "myapp-staging" WITH PASSWORD 'secure_password_here';

-- Modifier le mot de passe
ALTER USER "myapp-alpha" WITH PASSWORD 'new_password';

-- Donner tous les droits sur une base
GRANT ALL PRIVILEGES ON DATABASE "myapp-staging" TO "myapp-staging";

-- Supprimer un utilisateur
DROP USER "myapp-staging";
```

### Exploration des données

```sql
-- Lister les tables
\dt

-- Lister les tables avec tailles
\dt+

-- Structure d'une table
\d users

-- Compter les lignes
SELECT COUNT(*) FROM users;

-- Voir les 10 premières lignes
SELECT * FROM users LIMIT 10;

-- Rechercher
SELECT * FROM users WHERE email LIKE '%@example.com';
```

---

## Commandes one-liner (sans shell interactif)

### Exécuter une requête SQL directement

```bash
# Requête simple
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha -c "SELECT COUNT(*) FROM users;"

# Requête complexe (avec heredoc)
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha <<'SQL'
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
SQL
```

### Export de données

```bash
# Export CSV d'une table
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha \
  -c "COPY users TO STDOUT WITH CSV HEADER" > users_export.csv

# Export avec requête personnalisée
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha \
  -c "COPY (SELECT id, email FROM users WHERE created_at > '2024-01-01') TO STDOUT WITH CSV HEADER" > recent_users.csv
```

### Import de données

```bash
# Import CSV dans une table existante
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha \
  -c "COPY users FROM STDIN WITH CSV HEADER" < users_import.csv
```

---

## Sauvegarde et restauration

### Backup manuel d'une base

```bash
# Dump complet (format custom, compressé)
pgexec pg_dump -h 127.0.0.1 -U postgres -Fc myapp-alpha > myapp-alpha_$(date +%Y%m%d).dump

# Dump SQL (lisible)
pgexec pg_dump -h 127.0.0.1 -U postgres myapp-alpha > myapp-alpha_$(date +%Y%m%d).sql

# Dump d'une table spécifique
pgexec pg_dump -h 127.0.0.1 -U postgres -t users myapp-alpha > users_backup.sql
```

### Restauration

Les objets appartiennent au rôle de l'application (`--no-owner --role`) :

```bash
# Restaurer depuis un dump custom
pgexec pg_restore -h 127.0.0.1 -U postgres -d myapp-alpha --no-owner --role=myapp-alpha \
  --clean --if-exists < myapp-alpha_20240115.dump

# Restaurer depuis un dump SQL
pgexec psql -h 127.0.0.1 -U postgres -d myapp-alpha < myapp-alpha_20240115.sql
```

### Backup automatique (CronJobs)

Voir [`postgres-backup.md`](postgres-backup.md) (emplacement des dumps, copie hors du
serveur, restauration).

```bash
kubectl get cronjobs -n storage
kubectl create job --from=cronjob/postgres-backup-daily manual-backup-$(date +%s) -n storage
kubectl logs -n storage -l app.kubernetes.io/name=postgres-backup --tail=50
```

---

## Migration de données entre environnements

### Copier une base vers un autre environnement

```bash
# 1. Dump de la source
pgexec pg_dump -h 127.0.0.1 -U postgres -Fc --no-owner myapp-alpha > /tmp/myapp-alpha.dump

# 2. Créer la base cible si nécessaire (onboard-app.sh, ou section "Gestion des bases")

# 3. Restaurer vers la cible
pgexec pg_restore -h 127.0.0.1 -U postgres -d myapp-staging --no-owner --role=myapp-staging \
  --clean --if-exists < /tmp/myapp-alpha.dump

# Nettoyage
rm /tmp/myapp-alpha.dump
```

### Copier seulement certaines tables

```bash
# Dump des tables spécifiques
pgexec pg_dump -h 127.0.0.1 -U postgres \
  -t users -t roles -t permissions myapp-alpha > /tmp/auth_tables.sql

# Restaurer
pgexec psql -h 127.0.0.1 -U postgres -d myapp-staging < /tmp/auth_tables.sql
```

---

## Maintenance

### Statistiques et performances

```sql
-- Connexions actives
SELECT * FROM pg_stat_activity WHERE datname = 'myapp-alpha';

-- Tuer une connexion bloquante
SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
WHERE datname = 'myapp-alpha' AND pid <> pg_backend_pid();

-- Tables les plus volumineuses
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;

-- Index inutilisés
SELECT indexrelid::regclass as index, relid::regclass as table
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND indexrelid NOT IN (
    SELECT indexrelid FROM pg_constraint WHERE contype = 'p'
);
```

### Vacuum et maintenance

```sql
-- Analyser une table (mise à jour des stats)
ANALYZE users;

-- Vacuum (récupérer l'espace)
VACUUM users;

-- Vacuum complet (bloquant mais plus efficace)
VACUUM FULL users;

-- Vacuum + Analyze sur toute la base
VACUUM ANALYZE;
```

### Réindexation

```sql
-- Réindexer une table
REINDEX TABLE users;

-- Réindexer toute la base
REINDEX DATABASE "myapp-alpha";
```

---

## Dépannage

### Base corrompue ou inaccessible

```bash
# Vérifier l'état du pod
kubectl describe pod -n storage postgresql-0

# Logs PostgreSQL
kubectl logs -n storage postgresql-0 --tail=100

# Redémarrer PostgreSQL
kubectl rollout restart statefulset/postgresql -n storage
```

### Espace disque saturé

```bash
# Vérifier l'espace dans le pod
kubectl exec -n storage postgresql-0 -- df -h

# Identifier les grosses tables
pgexec psql -h 127.0.0.1 -U postgres -c "
SELECT nspname || '.' || relname AS relation,
       pg_size_pretty(pg_total_relation_size(C.oid)) AS total_size
FROM pg_class C
LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
WHERE nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(C.oid) DESC
LIMIT 20;
"
```

### Connexions saturées

```sql
-- Voir les connexions par base
SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;

-- Voir les connexions par état
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;

-- Voir les requêtes longues
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;
```

---

## Commandes rapides (copier-coller)

```bash
# === CONNEXION ===
kubectl exec -it -n storage postgresql-0 -c postgresql -- \
    sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec psql -h 127.0.0.1 -U postgres'

# === CREDENTIALS ADMIN ===
sudo ./vps/scripts/export-secrets.sh show postgres

# === CREDENTIALS APP ===
kubectl get secret -n myapp-alpha myapp-db -o json | jq '.data | map_values(@base64d)'

# === BACKUP RAPIDE (fonction pgexec ci-dessus) ===
pgexec pg_dump -h 127.0.0.1 -U postgres myapp-alpha > backup_$(date +%Y%m%d_%H%M).sql

# === PORT FORWARD ===
kubectl port-forward -n storage svc/postgresql 5432:5432
```
