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
│  │  ArgoCD     │    │  Keycloak   │    │ PostgreSQL  │    │  Ingress    │  │
│  │  (GitOps)   │    │  (Auth)     │    │  (Storage)  │    │  (nginx)    │  │
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

- `vps/install.sh` - Main installation script
- `vps/argocd/values.yaml` - ArgoCD configuration
- `vps/postgresql/values.yaml` - PostgreSQL configuration
- `vps/keycloak/values.yaml` - Keycloak configuration

### Phase 2: Ingress & TLS Setup

**Script:** `vps/scripts/setup-ingress.sh`

```
┌──────────────────────────────────────────────────────────────────┐
│                  setup-ingress.sh Execution Flow                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Install nginx       │
                   │  Ingress Controller  │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Install cert-manager│
                   │  (if --tls flag)     │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create ClusterIssuer│
                   │  (letsencrypt-prod)  │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create Ingress for: │
                   │  - Keycloak (auth.)  │
                   │  - (Grafana blocked) │
                   └──────────────────────┘
```

**Security notes:**

- Grafana/Prometheus: Access via `kubectl port-forward` only
- Keycloak: Only specific paths are exposed (path-based routing):
  - `/realms/*` - OAuth/OIDC endpoints
  - `/resources/*` - Login page assets
- Keycloak `/admin/*`: NOT routed (access via `kubectl port-forward` only)
- This approach avoids `server-snippet` annotations which are blocked by nginx-ingress for security

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
                   │  Create Secret:      │
                   │  github-repo-creds   │
                   │  in argocd namespace │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Add Label:          │
                   │  argocd.argoproj.io/ │
                   │  secret-type=        │
                   │  repo-creds          │
                   └──────────────────────┘
```

**Important:** This secret allows ArgoCD to pull from private Git repositories.

### Phase 4: Application Onboarding

**Script:** `vps/scripts/onboard-app.sh <app-name>`

```
┌──────────────────────────────────────────────────────────────────┐
│                  onboard-app.sh Execution Flow                   │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create Namespaces:  │
                   │  - <app>-alpha       │
                   │  - <app>-prod        │
                   │  (with ResourceQuota │
                   │   and LimitRange)    │
                   └──────────┬───────────┘
                              │
                              ▼
                   ┌──────────────────────┐
                   │  Create PostgreSQL   │
                   │  databases & users:  │
                   │  - <app>-alpha       │
                   │  - <app>-prod        │
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
                   │  Create CI/CD        │
                   │  ServiceAccounts &   │
                   │  Kubeconfigs         │
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
- Kubeconfigs in `/root/.k3s-secrets/kubeconfigs/`
- Secrets created directly in namespaces (not SealedSecrets)

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
                   │  - postgresql creds  │
                   │  - keycloak client   │
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

### Phase 6: ArgoCD Application Deployment

**Trigger:** Git push to repository (or manual sync)

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
│     │  - Ingress                                          │   │
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

**Solution:** Create properly labeled secret:

```bash
kubectl create secret generic github-repo-creds -n argocd \
    --from-literal=type=git \
    --from-literal=url=https://github.com/<org> \
    --from-literal=username=git \
    --from-literal=password=<token>

kubectl label secret github-repo-creds -n argocd \
    argocd.argoproj.io/secret-type=repo-creds
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

| Script              | Purpose                      |
|---------------------|------------------------------|
| `install.sh`        | Initial cluster setup        |
| `setup-ingress.sh`  | Ingress & TLS configuration  |
| `onboard-app.sh`    | Per-application setup        |
| `export-secrets.sh` | Secure credential management |
| `setup-secrets.sh`  | Secret rotation              |

### Application Helm Chart (`helm/<app>/`)

| File                                   | Purpose                             |
|----------------------------------------|-------------------------------------|
| `values.yaml`                          | Default configuration               |
| `values-alpha.yaml`                    | Alpha environment overrides         |
| `values-prod.yaml`                     | Production environment overrides    |
| `templates/deployment.yaml`            | Pod specification with env vars     |
| `templates/sealed-secrets.yaml`        | Encrypted secrets (not ghcr-secret) |
| `templates/migration-job-presync.yaml` | Database migrations (optional)      |

### ArgoCD Configuration (`vps/argocd/`)

| File                    | Purpose                         |
|-------------------------|---------------------------------|
| `values.yaml`           | ArgoCD Helm values              |
| `applicationset-*.yaml` | Dynamic app generation from Git |

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
