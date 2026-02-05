# 🗄️ Database Administration Guide

Guide complet pour administrer PostgreSQL sur le cluster K3s.

---

## Connexion à PostgreSQL

### Récupérer les credentials admin

```bash
# Mot de passe admin PostgreSQL
kubectl get secret -n storage postgresql -o jsonpath='{.data.postgres-password}' | base64 -d

# Afficher toutes les infos
kubectl get secret -n storage postgresql -o yaml
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
kubectl exec -it -n storage postgresql-0 -- psql -U postgres

# Connexion à une base spécifique
kubectl exec -it -n storage postgresql-0 -- psql -U postgres -d myapp-alpha
```

### Connexion avec utilisateur applicatif

```bash
APP=myapp
ENV=alpha
PASSWORD=$(kubectl get secret -n ${APP}-${ENV} ${APP}-db -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -it -n storage postgresql-0 -- env PGPASSWORD="$PASSWORD" psql -U ${APP}-${ENV} -d ${APP}-${ENV}
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
kubectl exec -n storage postgresql-0 -- psql -U postgres -d myapp-alpha -c "SELECT COUNT(*) FROM users;"

# Requête complexe (avec heredoc)
kubectl exec -i -n storage postgresql-0 -- psql -U postgres -d myapp-alpha <<'SQL'
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
kubectl exec -n storage postgresql-0 -- psql -U postgres -d myapp-alpha \
  -c "COPY users TO STDOUT WITH CSV HEADER" > users_export.csv

# Export avec requête personnalisée
kubectl exec -n storage postgresql-0 -- psql -U postgres -d myapp-alpha \
  -c "COPY (SELECT id, email FROM users WHERE created_at > '2024-01-01') TO STDOUT WITH CSV HEADER" > recent_users.csv
```

### Import de données

```bash
# Import CSV dans une table existante
cat users_import.csv | kubectl exec -i -n storage postgresql-0 -- \
  psql -U postgres -d myapp-alpha -c "COPY users FROM STDIN WITH CSV HEADER"
```

---

## Sauvegarde et restauration

### Backup manuel d'une base

```bash
# Dump complet (format custom, compressé)
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres -Fc myapp-alpha > myapp-alpha_$(date +%Y%m%d).dump

# Dump SQL (lisible)
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres myapp-alpha > myapp-alpha_$(date +%Y%m%d).sql

# Dump d'une table spécifique
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres -t users myapp-alpha > users_backup.sql
```

### Restauration

```bash
# Restaurer depuis un dump custom
cat myapp-alpha_20240115.dump | kubectl exec -i -n storage postgresql-0 -- \
  pg_restore -U postgres -d myapp-alpha --clean --if-exists

# Restaurer depuis un dump SQL
cat myapp-alpha_20240115.sql | kubectl exec -i -n storage postgresql-0 -- \
  psql -U postgres -d myapp-alpha

# Restaurer une table spécifique
cat users_backup.sql | kubectl exec -i -n storage postgresql-0 -- \
  psql -U postgres -d myapp-alpha
```

### Backup automatique (CronJob existant)

```bash
# Voir le CronJob
kubectl get cronjob -n storage

# Déclencher un backup manuel
kubectl create job --from=cronjob/postgres-backup manual-backup-$(date +%s) -n storage

# Voir les logs du backup
kubectl logs -n storage -l job-name=manual-backup-xxx -f
```

---

## Migration de données entre environnements

### Copier une base vers un autre environnement

```bash
# 1. Dump de la source
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres -Fc myapp-alpha > /tmp/myapp-alpha.dump

# 2. Créer la base cible si nécessaire (voir section "Gestion des bases")

# 3. Restaurer vers la cible
cat /tmp/myapp-alpha.dump | kubectl exec -i -n storage postgresql-0 -- \
  pg_restore -U postgres -d myapp-staging --clean --if-exists

# Nettoyage
rm /tmp/myapp-alpha.dump
```

### Copier seulement certaines tables

```bash
# Dump des tables spécifiques
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres \
  -t users -t roles -t permissions myapp-alpha > /tmp/auth_tables.sql

# Restaurer
cat /tmp/auth_tables.sql | kubectl exec -i -n storage postgresql-0 -- \
  psql -U postgres -d myapp-staging
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
kubectl exec -n storage postgresql-0 -- psql -U postgres -c "
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
kubectl exec -it -n storage postgresql-0 -- psql -U postgres

# === CREDENTIALS ADMIN ===
kubectl get secret -n storage postgresql -o jsonpath='{.data.postgres-password}' | base64 -d && echo

# === CREDENTIALS APP ===
kubectl get secret -n myapp-alpha myapp-db -o json | jq '.data | map_values(@base64d)'

# === BACKUP RAPIDE ===
kubectl exec -n storage postgresql-0 -- pg_dump -U postgres myapp-alpha > backup_$(date +%Y%m%d_%H%M).sql

# === PORT FORWARD ===
kubectl port-forward -n storage svc/postgresql 5432:5432
```
