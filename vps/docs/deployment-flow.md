# K3s Stack Deployment Flow

This document describes the complete deployment flow for applications on the K3s stack, from initial cluster setup to
running applications with ArgoCD GitOps.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              VPS (K3s Cluster)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │  ArgoCD     │    │  Keycloak   │    │ PostgreSQL  │    │  Gateway    │  │
│  │  (GitOps)   │    │  (Auth)     │    │  (Storage)  │    │  (NGF)      │  │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘    └──────┬──────┘  │
│         │                  │                  │                  │         │
│         │    ┌─────────────┴──────────────────┴─────────────┐    │         │
│         │    │           Application Namespaces             │    │         │
│         │    │  ┌─────────────────┐  ┌─────────────────┐    │    │         │
│         └────┼─▶│  app-alpha      │  │  app-prod       │◀───┼────┘         │
│              │  │  (develop)      │  │  (main)         │    │              │
│              │  └─────────────────┘  └─────────────────┘    │              │
│              └──────────────────────────────────────────────┘              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      ▲
                                      │ HTTPS (Let's Encrypt)
                                      │
                              ┌───────┴───────┐
                              │   Internet    │
                              └───────────────┘
```

## Deployment Phases

### Phase 1: Cluster Installation

**Script:** `vps/install.sh`

```
┌──────────────────────────────────────────────────────────────────┐
│                    install.sh Execution Flow                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │   Install K3s        │
                   │   (with metrics-     │
                   │    server enabled)   │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │   Install Helm       │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Deploy Core Stack:  │
                   │  - Sealed Secrets    │
                   │  - PostgreSQL        │
                   │  - Keycloak          │
                   │  - ArgoCD            │
                   │  - Monitoring        │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Generate & Store    │
                   │  Credentials in      │
                   │  /root/.k3s-secrets  │
                   └──────────────────────┘
```

**Key files:**

- `vps/install.sh` - Main installation script (also installs cert-manager and the Let's Encrypt ClusterIssuers)
- `vps/config/versions.env` - Pinned versions
- `vps/config/k3s/config.yaml` - K3s flags (secrets encryption, audit log)
- `vps/values/*.yaml` - Helm values (Argo CD, PostgreSQL, NGINX Gateway Fabric, monitoring)
- `vps/templates/keycloak/` - Keycloak, with the theme and provider images of `KEYCLOAK_EXTENSION_IMAGES`
  (`vps/scripts/apply-keycloak.sh`)
- `vps/postgres-backup/` - backup CronJobs and optional off-site restic copy (`vps/scripts/apply-backups.sh`)

### Phase 2: Gateway & TLS Setup

**Script:** `vps/scripts/setup-gateway-api.sh [--staging] [--no-tls] [--dry-run]`

```
┌──────────────────────────────────────────────────────────────────┐
│               setup-gateway-api.sh Execution Flow                │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ Gateway: HTTP + one  │
                   │ HTTPS listener per   │
                   │ GATEWAY_HOSTNAMES    │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ One Certificate per  │
                   │ hostname (removed    │
                   │ hostnames pruned)    │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ HTTP -> HTTPS        │
                   │ redirection          │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ Keycloak routes on   │
                   │ AUTH_HOSTNAMES and   │
                   │ their rate limit     │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ CoreDNS hairpin:     │
                   │ pods resolve public  │
                   │ hostnames internally │
                   └──────────────────────┘
```

**Security notes:**

- Grafana, Prometheus, Alertmanager, Argo CD: `kubectl port-forward` only
- Keycloak: only `/realms/*` (OAuth/OIDC endpoints, HTTPRoute `keycloak`) and `/resources/*`
  (login assets, HTTPRoute `keycloak-resources`) are routed; the master realm is answered by
  the gateway, `/admin/*` is not routed
- The RateLimitPolicy `keycloak` limits the OIDC endpoints per client address
  (`KEYCLOAK_RATE_LIMIT_RATE`, `KEYCLOAK_RATE_LIMIT_BURST`, `429` above the burst); the login
  assets are not limited
- The gateway access logs carry the path without the query string (OAuth codes and states
  never logged); Promtail masks the tokens of `/stop/<token>` paths before Loki
- Applications attach their own HTTPRoutes to `infrastructure-gateway` (namespace
  `nginx-gateway`); their hostnames must be listed in `GATEWAY_HOSTNAMES`

### Phase 3: SCM Credentials (GitHub/GitLab)

**Script:** `vps/scripts/export-secrets.sh set-scm-credentials <provider>`

```
┌──────────────────────────────────────────────────────────────────┐
│              set-scm-credentials github Flow                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Prompt for the URL  │
                   │  prefix covering the │
                   │  organizations and   │
                   │  the token           │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Secrets in argocd:  │
                   │  - github-repo-creds │
                   │    (repo-creds)      │
                   │  - scm-token         │
                   │  - ghcr-registry-    │
                   │    secret            │
                   │  Secret in security: │
                   │  - ghcr-secret       │
                   └──────────────────────┘
```

**Important:** these Secrets let Argo CD discover and pull the private repositories of every
organization of `SCM_ORGANIZATIONS` (`github-repo-creds`, `scm-token`), the Image Updater read
GHCR (`ghcr-registry-secret`) and Keycloak pull private extension images (`security/ghcr-secret`).

One token serves every organization: on GitHub, a **classic** personal access token with the
scopes `repo` and `read:packages` (a fine-grained token is limited to one owner, and GHCR only
accepts classic tokens). The credential template matches repository URLs by prefix:
`https://github.com/<org>` for one organization, `https://github.com/` for several.

### Phase 4: Application Onboarding

**Script:** `vps/scripts/onboard-app.sh <app-name> [--environment all|alpha|prod] [--organization ORG] [--skip-database] [--with-cicd]`

`--organization` names the organization of the repository, one of `SCM_ORGANIZATIONS` (default: the first one):
it sets the URL of the Argo CD repository Secret (`https://github.com/<org>/<app>.git`).

```
┌──────────────────────────────────────────────────────────────────┐
│                  onboard-app.sh Execution Flow                   │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │ Create selected ns:  │
                   │  - <app>-alpha and/or│
                   │  - <app>-prod        │
                   │  (with ResourceQuota │
                   │   and LimitRange)    │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create PostgreSQL   │
                   │ databases & users    │
                   │ for selected env(s)  │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create Secrets in   │
                   │  each namespace:     │
                   │  - <app>-db (DB creds)│
                   │  - ghcr-secret       │
                   │    (image pull)      │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  CI/CD access only   │
                   │  with --with-cicd    │
                   │  (SA & kubeconfig)   │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Save credentials to │
                   │  /root/.k3s-secrets/ │
                   │  <app>.env           │
                   └──────────────────────┘
```

**Outputs:**

- Database credentials in `/root/.k3s-secrets/<app>.env`
- Kubeconfigs in `/root/.k3s-secrets/kubeconfigs/` (with `--with-cicd`)
- Secrets created directly in namespaces (not SealedSecrets); the URLs of `<app>-db` require TLS

For a production-only onboarding of a repository of the organization `other-org`:

```bash
sudo ./vps/scripts/onboard-app.sh my-app --environment prod --organization other-org
```

The script preserves a known PostgreSQL password and refuses to rotate an existing account when its password is
unavailable or inconsistent. Do not rerun the broad `all` scope for a single-environment repair.

### Phase 5: Sealed Secrets Generation (Developer Machine)

**Location:** Developer's local machine

```
┌──────────────────────────────────────────────────────────────────┐
│              Sealed Secrets Generation Flow                      │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Export public cert  │
                   │  from VPS:           │
                   │  export-secrets.sh   │
                   │  export-cert /tmp/   │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Copy cert to local  │
                   │  machine via scp     │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create SealedSecret │
                   │  using kubeseal:     │
                   │  - PostgreSQL password│
                   │  - keycloak client   │
                   │  - application keys  │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Commit encrypted    │
                   │  SealedSecrets to    │
                   │  Git repository      │
                   └──────────────────────┘
```

**Note:** `ghcr-secret` is NOT a SealedSecret - it's created by `onboard-app.sh` to avoid chicken-and-egg issues with
PreSync hooks.

Seal each production value from the application repository, typed without echo and never passed as a command
argument (`kubeseal --raw` prints only the encrypted value, bound to the namespace and Secret name):

```bash
read -r -s -p "Value: " VALUE; echo
printf '%s' "$VALUE" | kubeseal --raw --cert ~/.k3s-secrets/sealed-secrets-pub.pem \
    --namespace my-app-prod --name my-app-secrets --from-file=/dev/stdin
unset VALUE
```

Copy the encrypted values into `helm/<app>/values-prod.yaml`. Never put raw application keys in Git or chat.
If onboarding created a new database password, seal that exact password the same way and update the
corresponding `encryptedData` value before allowing Argo CD to sync.

### Phase 6: ArgoCD Application Deployment

**Trigger:** Git push starts the application build; Argo CD Image Updater polls GHCR for the branch-qualified immutable
image tag, and ArgoCD automated sync deploys the updated tag. Image Updater polls the registry; it is not a build
webhook.

The configured tags are `develop-<full-sha>` for Alpha and `main-<full-sha>` for production; this prevents one branch's
build from being selected into the other environment.

The ApplicationSets hold one SCM provider generator per organization of `SCM_ORGANIZATIONS`. Each generator carries
the image path of its organization (`values.imageBase`: `REGISTRY_HOST/<organization, lowercased>`, or `REGISTRY_BASE`
for a single organization), used by the Image Updater annotation and the `image.repository` parameter:
`ghcr.io/<organization>/<repository>`. GHCR paths are lowercase; repository names must be lowercase and unique across
the organizations (they name the Applications and the namespaces).

- **Prod**: every repository whose default branch holds `helm/` gets `<repository>-prod`, following `main`.
- **Alpha**: only the repositories having a `develop` branch that holds `helm/` get `<repository>-alpha` (generator
  listing every branch, filter `branchMatch: ^develop$` combined with `pathsExist: [helm]`, checked on that branch).
  When a repository loses its `develop` branch, the ApplicationSet deletes its alpha Application and resources.

After changing the ApplicationSet templates (`vps/templates/argocd/`) or `SCM_ORGANIZATIONS` / `REGISTRY_HOST` /
`REGISTRY_BASE`, render and apply them again:

```bash
sudo ./vps/scripts/apply-config.sh
```

```
┌──────────────────────────────────────────────────────────────────┐
│                  ArgoCD Sync Flow                                │
└──────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌───────────────┐                         ┌───────────────┐
│ ApplicationSet│                         │ ApplicationSet│
│ (alpha)       │                         │ (prod)        │
│ branch:develop│                         │ branch:main   │
└───────┬───────┘                         └───────┬───────┘
        │                                         │
        ▼                                         ▼
┌───────────────────────────────────────────────────────────────┐
│                     ArgoCD Sync Phases                        │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  1. PreSync (if migration.enabled: true)                      │
│     ┌─────────────────────────────────────────────────────┐   │
│     │  Migration Job                                      │   │
│     │  - Uses: ghcr-secret (created by onboard-app.sh)    │   │
│     │  - Uses: default ServiceAccount                     │   │
│     │  - Runs: Liquibase migrations                       │   │
│     │  - Hook: argocd.argoproj.io/hook: PreSync           │   │
│     └─────────────────────────────────────────────────────┘   │
│                           │                                   │
│                           ▼ (on success)                      │
│  2. Sync                                                      │
│     ┌─────────────────────────────────────────────────────┐   │
│     │  Deploy Resources:                                  │   │
│     │  - SealedSecrets → Secrets (by controller)          │   │
│     │  - ServiceAccount                                   │   │
│     │  - Deployment                                       │   │
│     │  - Service                                          │   │
│     │  - HTTPRoute                                        │   │
│     │  - NetworkPolicy                                    │   │
│     │  - HPA (if enabled)                                 │   │
│     └─────────────────────────────────────────────────────┘   │
│                                                               │
│  3. PostSync (optional, not currently used)                   │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

### Phase 7: Application Startup

```
┌──────────────────────────────────────────────────────────────────┐
│                  Application Startup Flow                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Pod Scheduled       │
                   │  - Pull image from   │
                   │    GHCR (ghcr-secret)│
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Spring Boot Starts  │
                   │  - Reads env vars    │
                   │    from Deployment   │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  OIDC Discovery      │
                   │  (INTERNAL URL)      │
                   │  ┌────────────────┐  │
                   │  │ keycloak.      │  │
                   │  │ security.svc.  │  │
                   │  │ cluster.local  │  │
                   │  │ /realms/<realm>│  │
                   │  └────────────────┘  │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Liquibase Migrations│
                   │  (if PreSync disabled│
                   │   or first run)      │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Health Checks Pass  │
                   │  - /actuator/health/ │
                   │    liveness          │
                   │  - /actuator/health/ │
                   │    readiness         │
                   └──────────────────────┘
```

## Important Pitfalls & Solutions

### 1. OIDC Discovery TLS Error

**Problem:** Spring Boot fails to validate Let's Encrypt certificate when calling Keycloak externally.

**Solution:** Use internal URL for OIDC discovery:

```yaml
# deployment.yaml
-   name: OAUTH2_ISSUER_URI
    value: "{{ .Values.keycloak.internalUrl }}/realms/{{ .Values.keycloak.realm }}"
```

The `internalUrl` (`http://keycloak.security.svc.cluster.local`) bypasses TLS.

### 2. PreSync Hook Chicken-and-Egg

**Problem:** Migration job needs `ghcr-secret` and `ServiceAccount`, but these are created in Sync phase (after
PreSync).

**Solutions:**

- `ghcr-secret`: Created by `onboard-app.sh`, not via SealedSecret
- `ServiceAccount`: Migration job uses `default` SA
- Alternative: Disable PreSync migration (`migration.enabled: false`) and run Liquibase at app startup

### 3. ArgoCD Repo Credentials

**Problem:** ArgoCD can't access private GitHub repos.

**Solution:** create the labeled credentials (the token is read without echo and never
passed as a command argument):

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

### 4. Sealed Secrets Scope

**Problem:** SealedSecrets are namespace-scoped by default.

**Solution:** Use `namespace-wide` annotation:

```yaml
metadata:
    annotations:
        sealedsecrets.bitnami.com/namespace-wide: "true"
```

Seal with the same scope: `kubeseal --raw --scope namespace-wide --namespace <app>-<env> ...` (no `--name`).

### 5. SealedSecret Not Decrypted

**Problem:** `no key could decrypt secret (<key>)`: one value was sealed with another certificate (the local k3d
cluster, for example). The whole SealedSecret is rejected, Argo CD reports the application `Degraded`, and a pod
referencing the Secret without `optional: true` stays in `CreateContainerConfigError`.

**Solution:** seal every value with the certificate of the VPS (`export-secrets.sh export-cert`).

### 6. Application NetworkPolicy

**Problem:** `Connection refused` towards a platform service, although the platform policies allow the application
namespaces: the NetworkPolicy of the application chart restricts its own egress.

**Solution:** allow egress to every platform service the application uses: `storage` 5432 (PostgreSQL),
`database` 6379 (Redis), `security` 8080 (Keycloak: NetworkPolicies match the pod port, not the port 80 of its
Service) and DNS. An application sending emails also needs 587 (or 465) towards its SMTP relay.

### 7. Rolling Update Refused by the Quota

**Problem:** `exceeded quota: <app>-<env>-quota, requested: limits.cpu=...`: during a rolling update the old and the
new pod run together.

**Solution:** the namespace quota limits (`vps/config/onboarding/<env>.env`) must hold twice the largest pod: lower
the pod limits, or raise the quota and run `onboard-app.sh <app>` again.

## File Reference

### VPS Scripts (`vps/scripts/`)

| Script                 | Purpose                                         |
|------------------------|-------------------------------------------------|
| `install.sh`           | Initial cluster setup (in `vps/`)               |
| `setup-gateway-api.sh` | Gateway, certificates, Keycloak routes and rate limit, hairpin |
| `apply-config.sh`      | Argo CD ApplicationSets and Image Updater CRs   |
| `apply-keycloak.sh`    | Keycloak and its extension images (themes, providers) |
| `apply-backups.sh`     | PostgreSQL backup CronJobs, off-site restic copy |
| `onboard-app.sh`       | Per-application setup                           |
| `export-secrets.sh`    | Credentials, sealing key backup, SCM access     |
| `setup-secrets.sh`     | Infrastructure secrets, rotation, Discord, off-site backup credentials |
| `harden-host.sh`       | Firewall, SSH and automatic updates             |
| `k3s-maintenance.sh`   | K3s backups, restores and upgrades              |
| `setup-remote.sh`      | Workstation kubeconfig through an SSH tunnel    |

Parameters of every script: [`../README.md`](../README.md).

### Example applications

Two public repositories illustrate the two common kinds of applications:

- [DevDeNiro/coterie-webapp-alpha](https://github.com/DevDeNiro/coterie-webapp-alpha): Java server-side monolith
  (Spring Boot / Kotlin, HTML rendered with HTMX) using PostgreSQL, Redis and Keycloak;
- [DevDeNiro/react-starter-kit](https://github.com/DevDeNiro/react-starter-kit): client application (React / Vite
  build served by nginx), without database (`onboard-app.sh <app> --skip-database`).

The auto-discovery deploys a repository of one of the organizations of `SCM_ORGANIZATIONS` once it follows the layout
below: a chart in `helm/<repository>/` with `values-prod.yaml` (and `values-alpha.yaml` with a `develop` branch), a
`main` branch, images `ghcr.io/<organization>/<repository>` tagged `main-<sha>` (and `develop-<sha>`).

### Application Helm Chart (`helm/<app>/`)

| File                                   | Purpose                             |
|----------------------------------------|-------------------------------------|
| `values.yaml`                          | Default configuration               |
| `values-alpha.yaml`                    | Alpha environment overrides         |
| `values-prod.yaml`                     | Production environment overrides    |
| `templates/deployment.yaml`            | Pod specification with env vars     |
| `templates/sealed-secrets.yaml`        | Encrypted secrets (not ghcr-secret) |
| `templates/migration-job-presync.yaml` | Database migrations (optional)      |

### Argo CD Configuration

| File                                          | Purpose                         |
|-----------------------------------------------|---------------------------------|
| `vps/values/argocd.yaml`                      | Argo CD Helm values             |
| `vps/templates/argocd/applicationsets.yaml.tpl` | Dynamic app generation from Git |
| `vps/templates/argocd/generator-{alpha,prod}.yaml.tpl` | One SCM generator per organization |
| `vps/manifests/argocd-image-updaters.yaml`    | Image Updater CRs (alpha, prod) |

## Quick Reference Commands

```bash
# Check ArgoCD sync status
sudo kubectl get applications -n argocd

# View app logs
sudo kubectl logs -f -n <app>-alpha deploy/<app>-alpha

# Force ArgoCD refresh
sudo kubectl -n argocd patch application <app>-alpha \
    --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Reset stuck ArgoCD operation
sudo kubectl -n argocd patch application <app>-alpha \
    --type json -p '[{"op":"remove","path":"/status/operationState"}]'

# View sealed-secrets controller logs
sudo kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets

# Export credentials
sudo ./vps/scripts/export-secrets.sh show <service>
```
