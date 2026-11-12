# Historical in-place migrations

> Archived transition procedures for older installations. They are not a current upgrade plan; review backups and test any migration before use.

## Isolating the applications on an existing VPS

An installation made before the application isolation gets it in place, without
reinstallation. On the server, as root, from the updated clone (`git pull`,
`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`), in this order:

1. **Checks**: no application chart renders a resource refused by its future AppProject,
   and the alpha namespaces accept the `restricted` level (no warning).

   ```bash
   helm template <app> <chart-dir> -f <chart-dir>/values-alpha.yaml \
       | grep -E '^kind: (Namespace|Cluster[A-Za-z]*|CustomResourceDefinition|[A-Za-z]*WebhookConfiguration|PriorityClass|StorageClass|PersistentVolume|ResourceQuota|LimitRange|Endpoints|EndpointSlice)$'
   kubectl label --dry-run=server --overwrite ns <app>-alpha pod-security.kubernetes.io/enforce=restricted
   ```

2. **Two tokens**: the read-only image pull token first, then the repository token, ideally
   of a read-only machine account. Revoke the former token (`repo` and `read:packages`)
   afterwards: it was readable in every application namespace.

   ```bash
   ./vps/scripts/export-secrets.sh set-registry-credentials
   ./vps/scripts/export-secrets.sh set-scm-credentials github
   ```

3. **Applications**: onboard every existing application again, with its organization and
   environments. Passwords are kept; it adds the AppProject, the default NetworkPolicy, the
   `restricted` level of alpha, the closing of the databases to the other roles and the new
   pull Secret. Then close the Keycloak database the same way.

   ```bash
   ./vps/scripts/onboard-app.sh <app> --organization <org> [--environment prod]
   PGPW=$(kubectl get secret postgresql-secret -n storage -o jsonpath='{.data.postgres-password}' | base64 -d)
   printf '%s\n' "$PGPW" | kubectl exec -i -n storage postgresql-0 -c postgresql -- sh -c \
       'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -h 127.0.0.1 -U postgres -d postgres -X -c "REVOKE ALL ON DATABASE keycloak FROM PUBLIC"'
   unset PGPW
   ```

4. **Argo CD**, only after step 3 (the Applications would otherwise land in the emptied
   `default` project): one project per application, no namespace creation. The script lists
   the Applications left without project.

   ```bash
   ./vps/scripts/apply-config.sh
   kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status'
   ```

5. **NetworkPolicies** of the namespaces `monitoring` and `argocd`:

   ```bash
   kubectl apply -f vps/manifests/network-policies.yaml
   ```

6. **Gateway**: write each entry of `GATEWAY_HOSTNAMES` as `<hostname>=<namespace>` (the
   former format is refused with an explicit message), then apply. Every HTTPRoute must
   stay accepted.

   ```bash
   nano vps/config.env && ./vps/scripts/apply-config.sh --check
   ./vps/scripts/setup-gateway-api.sh
   kubectl get httproutes -A -o custom-columns='NS:.metadata.namespace,ROUTE:.metadata.name,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'
   ```

7. **Shared Redis**: once no application uses `redis.database.svc.cluster.local` any more (each one runs its cache in
   its own chart), remove it with its namespace:

   ```bash
   kubectl delete namespace database
   ```

8. **Former CI/CD accounts** (`onboard-app.sh --with-cicd`, removed), if any:

   ```bash
   kubectl get serviceaccounts -A --field-selector metadata.name=deployer
   kubectl delete -n <namespace> --ignore-not-found serviceaccount/deployer role/deployer-role \
       rolebinding/deployer-binding secret/deployer-token
   rm -rf /root/.k3s-secrets/kubeconfigs
   ```

9. **Keycloak**: no application may hold a credential of the realm `master` (an application
   manages its realm with a service account of that realm). Then enable the brute force
   detection of the realm `master` and an OTP for its administrator ([
   `docs/security-hardening.md`](../security-hardening.md), known limits).

## Applying the multi-organization change to an existing VPS

An installation made before the multi-organization discovery, the Keycloak extensions, the
gateway rate limit, the access log hygiene and the off-site backups gets them in place,
without reinstallation. On the server, as root, from the updated clone:

```bash
cd <clone>/k3s-stack && git pull
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

1. **`vps/config.env`**: add the new variables (`vps/config.env.example` documents them),
   then validate the file.

   ```bash
   # SCM_ORGANIZATIONS="my-org other-org"   the current organization first (default of onboard-app.sh)
   # REGISTRY_HOST="ghcr.io"                 remove REGISTRY_BASE when several organizations are listed
   # KEYCLOAK_EXTENSION_IMAGES="ghcr.io/my-org/my-app-keycloak-theme:1.0.0"
   # KEYCLOAK_RATE_LIMIT_RATE="10r/s"; KEYCLOAK_RATE_LIMIT_BURST="20"
   # OFFSITE_BACKUP_REPOSITORY="s3:https://s3.fr-par.scw.cloud/my-bucket/k3s-stack"; OFFSITE_BACKUP_REGION="fr-par"
   nano vps/config.env
   ./vps/scripts/apply-config.sh --check
   ```

2. **Image pull and repository access** for every organization, before the new generators
   and the Keycloak extension images need them (two tokens, see `export-secrets.sh`):

   ```bash
   ./vps/scripts/export-secrets.sh set-registry-credentials
   ./vps/scripts/export-secrets.sh set-scm-credentials github
   ```

3. **Auto-discovery**: one generator per organization. Alpha Applications of repositories
   without a `develop` branch are deleted (with their resources).

   ```bash
   ./vps/scripts/apply-config.sh
   kubectl get applicationsets,applications -n argocd
   ```

4. **Logs**: migrate Promtail to Alloy and verify redaction using the
   [observability migration procedure](../observability.md#notes-for-vps-upgrades),
   then enable JSON access logs without query strings (NGINX reloads, no downtime):

   ```bash
   source vps/config/versions.env
   helm upgrade nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version "$NGINX_GATEWAY_FABRIC_VERSION" \
       -n nginx-gateway -f vps/values/nginx-gateway-fabric.yaml --wait
   ```

5. **Keycloak**: SMTP egress for the realm emails, then the template with the extension
   images (restart: logins unavailable for 1 to 2 minutes).

   ```bash
   kubectl apply -f vps/manifests/network-policies.yaml
   ./vps/scripts/apply-keycloak.sh
   ```

6. **Gateway**: Keycloak routes split (`keycloak`, `keycloak-resources`) and rate limit of
   the OIDC endpoints.

   ```bash
   ./vps/scripts/setup-gateway-api.sh
   kubectl get httproutes,ratelimitpolicies -n security
   ```

7. **Off-site backups**: credentials, then the backup chart, then a first copy (it creates
   the repository).

   ```bash
   ./vps/scripts/setup-secrets.sh set-offsite-backup
   ./vps/scripts/apply-backups.sh
   kubectl create job --from=cronjob/postgres-backup-offsite offsite-first-$(date +%s) -n storage
   kubectl logs -n storage -l app.kubernetes.io/component=offsite -f
   ```

8. **Applications**: onboard the repositories of the other organizations, and onboard the
   existing applications again to refresh their repository Secret with the new token.

   ```bash
   ./vps/scripts/onboard-app.sh <app> --environment prod --organization <org>
   ```

Rollback: `KEYCLOAK_RATE_LIMIT_RATE="off"` then `setup-gateway-api.sh` removes the rate
limit; an empty `KEYCLOAK_EXTENSION_IMAGES` then `apply-keycloak.sh` restores the plain
Keycloak; an empty `OFFSITE_BACKUP_REPOSITORY` then `apply-backups.sh` removes the off-site
CronJobs (the repository and its snapshots stay in the bucket).
