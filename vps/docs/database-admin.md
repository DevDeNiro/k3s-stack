# Administration PostgreSQL

PostgreSQL est partagé dans `storage`. L'onboarding crée un rôle, une base et un Secret
`<app>-db` par environnement sélectionné ; les bases applicatives sont fermées aux autres
rôles. Les URLs du Secret exigent TLS. Les mots de passe sont conservés dans
`/root/.k3s-secrets/<app>.env` et doivent être sauvegardés hors du serveur.

## Connexion administrateur

La fonction suivante lit le mot de passe dans le pod, sans l'exposer dans les arguments :

```bash
pgexec() {
    kubectl exec -i -n storage postgresql-0 -c postgresql -- \
        sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec "$@"' sh "$@"
}
pgexec psql -h 127.0.0.1 -U postgres -d postgres -c '\l'
```

Pour un shell interactif :

```bash
kubectl exec -it -n storage postgresql-0 -c postgresql -- \
    sh -c 'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" exec psql -h 127.0.0.1 -U postgres'
```

Dans `psql`, `\l` liste les bases, `\du` les rôles et `\dt` les tables de la base courante.
Pour un outil externe, utiliser `kubectl port-forward -n storage svc/postgresql 5432:5432`.

## Diagnostic

```bash
# État et journaux
kubectl get pods -n storage
kubectl logs -n storage postgresql-0 -c postgresql --tail=100

# Taille et connexions par base
pgexec psql -h 127.0.0.1 -U postgres -d postgres -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC"
pgexec psql -h 127.0.0.1 -U postgres -d postgres -c \
  "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname"
```

Pour un échec de connexion applicative, vérifier le Secret `<app>-db`, le label
`app.kubernetes.io/managed-by=k3s-stack` du namespace et la NetworkPolicy de sortie de
l'application.

## Sauvegarde et restauration

Les CronJobs sauvegardent les bases `*-prod` et Keycloak ; les bases alpha ne sont pas
incluses par défaut. Un job réussi ne garantit pas que chaque dump a réussi. Les dumps
contiennent des données en clair : les conserver chiffrés hors du serveur.

Procédures, vérification des journaux et exercice de restauration :
[postgres-backup.md](postgres-backup.md). Tester la restauration sur un cluster isolé
avant la mise en service ; une restauration en place peut écraser les données existantes.
