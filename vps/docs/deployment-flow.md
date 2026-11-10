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
- `vps/manifests/keycloak.yaml` - Keycloak

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
                   │ AUTH_HOSTNAMES       │
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
- Keycloak: only `/realms/*` (OAuth/OIDC endpoints) and `/resources/*` (login assets)
  are routed; the master realm is answered by the gateway, `/admin/*` is not routed
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
                   │  Prompt for GitHub   │
                   │  org URL & token     │
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
                   └──────────────────────┘
```

**Important:** these Secrets let Argo CD discover and pull the private repositories
(`github-repo-creds`, `scm-token`) and the Image Updater read GHCR (`ghcr-registry-secret`).

### Phase 4: Application Onboarding

**Script:** `vps/scripts/onboard-app.sh <app-name> [--environment all|alpha|prod] [--skip-database] [--with-cicd]`

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

For a production-only onboarding:

```bash
sudo ./vps/scripts/onboard-app.sh coterie-webapp --environment prod
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
                   │  - Turnstile/VAPID   │
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

For Coterie's production application keys, run this from the `coterie-webapp` checkout. The script prompts without
echoing the values and writes only encrypted values:

```bash
./scripts/seal-secrets.sh application coterie-webapp-prod \
    --cert ~/.k3s-secrets/sealed-secrets-pub.pem \
    --output /tmp/coterie-webapp-prod-sealed-values.yaml
```

Merge the generated `sealedSecrets.application` block into
`helm/coterie-webapp/values-prod.yaml`. Do not put raw Turnstile or VAPID values in Git or chat.
If onboarding created a new database password, seal that exact password with the hidden prompt and update the
`sealedSecrets.postgresql.encryptedData` value before allowing ArgoCD to sync.

### Phase 6: ArgoCD Application Deployment

**Trigger:** Git push starts the application build; Argo CD Image Updater polls GHCR for the branch-qualified immutable
image tag, and ArgoCD automated sync deploys the updated tag. Image Updater polls the registry; it is not a build
webhook.

The configured tags are `develop-<full-sha>` for Alpha and `main-<full-sha>` for production; this prevents one branch's
build from being selected into the other environment.

After changing the ApplicationSet template (`vps/templates/argocd/applicationsets.yaml.tpl`)
or `SCM_ORGANIZATION` / `REGISTRY_BASE`, render and apply it again:

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

## File Reference

### VPS Scripts (`vps/scripts/`)

| Script                 | Purpose                                         |
|------------------------|-------------------------------------------------|
| `install.sh`           | Initial cluster setup (in `vps/`)               |
| `setup-gateway-api.sh` | Gateway, certificates, Keycloak routes, hairpin |
| `apply-config.sh`      | Argo CD ApplicationSets and Image Updater CRs   |
| `onboard-app.sh`       | Per-application setup                           |
| `export-secrets.sh`    | Credentials, sealing key backup, SCM access     |
| `setup-secrets.sh`     | Infrastructure secrets, rotation, Discord       |
| `harden-host.sh`       | Firewall, SSH and automatic updates             |
| `k3s-maintenance.sh`   | K3s backups, restores and upgrades              |
| `setup-remote.sh`      | Workstation kubeconfig through an SSH tunnel    |

Parameters of every script: [`../README.md`](../README.md).

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
