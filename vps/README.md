# k3s-stack on a VPS

A single-node K3s platform for small production workloads: Gateway API routing with
Let's Encrypt certificates, PostgreSQL, Keycloak, Argo CD GitOps, Sealed Secrets,
metrics, logs and alerts, with the applications isolated from each other. Everything is
installed and operated by the scripts of this directory.

- Guided first installation: [`docs/vps-deployment.md`](docs/vps-deployment.md)
- Security model and migration of an existing VPS: [`docs/security-hardening.md`](docs/security-hardening.md)
- Workstation access (SSH tunnel, kubectl, k9s): [`docs/workstation-setup.md`](docs/workstation-setup.md)
- Isolating the applications of a running VPS (AppProjects, hostname owners, default
  NetworkPolicies, two tokens, no shared
  Redis): [Isolating the applications on an existing VPS](#isolating-the-applications-on-an-existing-vps)
- Upgrading a running VPS to the multi-organization discovery, Keycloak extensions,
  gateway rate limit and off-site
  backups: [Applying the multi-organization change to an existing VPS](#applying-the-multi-organization-change-to-an-existing-vps)

## Principles

- **Configuration lives in files, scripts hold the logic.** No inline YAML in the
  scripts: they render templates or apply static files.
- **Reinstallation is the nominal path.** A major change (K3s flags, versions,
  hostnames of a fresh server) is applied with `uninstall.sh --all` then `install.sh`.
  Scripts are idempotent, but upgrading a live installation in place is not their goal.
- **Secrets never appear in command arguments** (process list, Kubernetes audit log):
  values travel through stdin or file descriptors, generated credentials stay in
  `/root/.k3s-secrets` (mode 0700/0600).
- **Versions are pinned** in [`config/versions.env`](config/versions.env).
- **Applications are isolated from each other.** An application is its namespaces
  `<app>-alpha` and `<app>-prod`, created by `onboard-app.sh` with everything that
  confines it: Pod Security `restricted`, quota, a NetworkPolicy that only lets in the
  namespace itself, the gateway and Prometheus, its own PostgreSQL role and database, and
  its Argo CD AppProject (its repository and its namespaces only). Without onboarding,
  Argo CD deploys nothing. Each public hostname belongs to the namespaces declared for it
  in `GATEWAY_HOSTNAMES`. Shared services are those that isolate their users (PostgreSQL
  roles, Keycloak realms); a cache such as Redis belongs to the chart of the application.
  Any chart can read the Secrets of its namespaces: they only hold credentials of the
  application and a read-only image pull token.

| Path               | Content                                                                                                                                |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| `config.env`       | Site settings (copy of `config.env.example`, not versioned)                                                                            |
| `config/`          | Versions, K3s flags and audit policy, SSH/APT hardening, onboarding sizing, Helm repositories                                          |
| `templates/`       | Manifests rendered from `config.env` with `envsubst` (Gateway, certificates, Keycloak, Argo CD, onboarding, backups, credential files) |
| `values/`          | Helm values of every chart                                                                                                             |
| `manifests/`       | Static manifests (NetworkPolicies, Image Updater CRs, emptied Argo CD `default` project)                                               |
| `namespaces/`      | Infrastructure namespaces and their Pod Security levels                                                                                |
| `sql/`             | psql scripts (roles, databases, password rotation)                                                                                     |
| `postgres-backup/` | Helm chart of the PostgreSQL backup CronJobs                                                                                           |
| `scripts/`         | Operation scripts; `scripts/lib/common.sh` is the shared library                                                                       |

## Components

| Component                                                                       | Version                         | Namespace       | Exposure                                                                            |
|---------------------------------------------------------------------------------|---------------------------------|-----------------|-------------------------------------------------------------------------------------|
| K3s (SQLite datastore, secrets encrypted at rest)                               | v1.37.2+k3s1                    | -               | API closed by the firewall, SSH tunnel                                              |
| Gateway API CRDs (shipped with K3s)                                             | v1.6.3                          | -               | -                                                                                   |
| NGINX Gateway Fabric (hostPorts 80/443, JSON access logs without query strings) | 2.8.1                           | `nginx-gateway` | public entry point                                                                  |
| cert-manager (Let's Encrypt HTTP-01)                                            | v1.21.3                         | `cert-manager`  | -                                                                                   |
| PostgreSQL (Bitnami chart, image pinned by digest)                              | chart 18.12.18, PostgreSQL 18.6 | `storage`       | in-cluster, TLS available                                                           |
| Keycloak (themes and providers from extension images)                           | 26.8.2                          | `security`      | `/realms` (rate limited) and `/resources` of `AUTH_HOSTNAMES`, master realm blocked |
| Argo CD + Image Updater                                                         | charts 10.18.0 / 1.4.2          | `argocd`        | port-forward                                                                        |
| Sealed Secrets                                                                  | chart 2.22.0                    | `kube-system`   | -                                                                                   |
| Prometheus, Alertmanager, node-exporter, kube-state-metrics                     | chart 29.47.1                   | `monitoring`    | port-forward                                                                        |
| Grafana                                                                         | chart 14.4.1                    | `monitoring`    | port-forward                                                                        |
| Loki + Alloy                                                                    | charts 21.2.1 / 1.15.0          | `monitoring`    | -                                                                                   |
| PostgreSQL backups (daily, weekly, monthly)                                     | `postgres-backup/`              | `storage`       | -                                                                                   |
| Off-site copy of the backups (optional, encrypted)                              | restic 0.19.1                   | `storage`       | S3-compatible object storage                                                        |

Steady-state memory: ~3.5 GB. 4 GB of RAM is the minimum, 6 GB is comfortable.

## Requirements

- Ubuntu 24.04 / 22.04 or Debian 12, amd64 (arm64: see the Prometheus note in
  `local/values/prometheus.yaml`), 4 GB RAM, 40 GB disk, root access.
- Incoming ports: 22 (SSH), 80 and 443. The Kubernetes API (6443) stays closed.
- DNS records of every hostname of `GATEWAY_HOSTNAMES` pointing to the VPS.

## Quick start

```bash
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
cp vps/config.env.example vps/config.env && nano vps/config.env
./vps/scripts/apply-config.sh --check

sudo ./vps/install.sh
sudo ./vps/scripts/export-secrets.sh backup-sealing-key      # then copy the .enc file off the server
sudo ./vps/scripts/setup-gateway-api.sh --staging            # check, then again without --staging
sudo ./vps/scripts/export-secrets.sh set-registry-credentials   # read-only image pull token
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github # repository token (argocd only)
sudo ./vps/scripts/onboard-app.sh <app> [--organization <org>]
sudo ./vps/scripts/setup-secrets.sh set-offsite-backup       # with OFFSITE_BACKUP_REPOSITORY

# On the workstation
./vps/scripts/setup-remote.sh <vps-host> --user <ssh-user>
```

## Configuration

### `vps/config.env`

| Variable                                                | Example                                                                 | Used by                                                                                                                         |
|---------------------------------------------------------|-------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `SCM_PROVIDER`                                          | `github` (or `gitlab`)                                                  | Argo CD repository discovery, `onboard-app.sh`                                                                                  |
| `SCM_ORGANIZATIONS`                                     | `my-org other-org`                                                      | one ApplicationSet generator per organization, repository credentials, `onboard-app.sh --organization`                          |
| `SCM_ORGANIZATION`                                      | `my-org`                                                                | single organization of older files, used when `SCM_ORGANIZATIONS` is empty                                                      |
| `REGISTRY_HOST`                                         | `ghcr.io` (default)                                                     | images `<REGISTRY_HOST>/<organization>/<repository>` (Applications, Image Updater), image pull Secrets                          |
| `REGISTRY_BASE`                                         | `ghcr.io/my-org` (empty by default)                                     | single organization only: fixed image path, takes precedence over `REGISTRY_HOST/<organization>`                                |
| `LETSENCRYPT_EMAIL`                                     | `admin@example.com`                                                     | ClusterIssuers                                                                                                                  |
| `GATEWAY_HOSTNAMES`                                     | `auth.example.com=security app.example.com=my-app-prod`                 | one HTTPS listener and certificate per hostname; only the HTTPRoutes of the namespaces after `=` (comma-separated) attach to it |
| `AUTH_HOSTNAMES`                                        | `auth.example.com`                                                      | Keycloak routes (each one also listed in `GATEWAY_HOSTNAMES`, as `<hostname>=security`)                                         |
| `KEYCLOAK_RATE_LIMIT_RATE`, `KEYCLOAK_RATE_LIMIT_BURST` | `10r/s`, `20` (defaults)                                                | rate limit per client address of the Keycloak OIDC endpoints (`off` disables it)                                                |
| `KEYCLOAK_EXTENSION_IMAGES`                             | `ghcr.io/my-org/my-app-keycloak-theme:1.0.0` (empty by default)         | Keycloak themes and providers ([image contract](#keycloak-extension-images))                                                    |
| `OFFSITE_BACKUP_REPOSITORY`                             | `s3:https://s3.fr-par.scw.cloud/my-bucket/k3s-stack` (empty by default) | off-site restic copy of the PostgreSQL dumps                                                                                    |
| `OFFSITE_BACKUP_REGION`                                 | `fr-par` (empty by default)                                             | region signing the object storage requests                                                                                      |

`./vps/scripts/apply-config.sh --check` validates the file without root access.

Image paths are lowercase: the organization is lowercased in `REGISTRY_HOST/<organization>`
(GitHub keeps the case of an organization login, GHCR refuses uppercase letters), and
repository names must be lowercase already (they name namespaces). Repository names must be
unique across the organizations.

### `vps/config/versions.env`

Every version installed by `install.sh` (and by the local mirror). Each one can be
overridden for a single run: `sudo K3S_VERSION=v1.37.2+k3s1 ./vps/install.sh`.
K3s v1.37 or later is required: it ships the Gateway API CRDs.

### Other configuration files

| File                                     | Effect                                                                          |
|------------------------------------------|---------------------------------------------------------------------------------|
| `config/k3s/config.yaml`                 | K3s flags (installed into `/etc/rancher/k3s/config.yaml`, kept across upgrades) |
| `config/k3s/audit-policy.yaml`           | Kubernetes audit policy (`/var/log/kubernetes/audit/audit.log`)                 |
| `config/ssh/10-k3s-stack-hardening.conf` | sshd drop-in of `harden-host.sh --harden-ssh`                                   |
| `config/apt/20auto-upgrades`             | unattended upgrades of `harden-host.sh --auto-updates`                          |
| `config/onboarding/{alpha,prod}.env`     | quota and Pod Security level of the application namespaces                      |
| `config/helm-repositories`               | Helm repositories added by `install.sh`                                         |
| `values/postgresql-image.yaml`           | PostgreSQL image digest, shared by the server and the backups                   |

## Scripts

All VPS scripts run as root (`sudo`) on the server, except `setup-remote.sh` (workstation)
and `apply-config.sh --check`. Every script prints its usage with `--help`. An unexpected
failure prints the failing command and line.

### `install.sh`

```text
sudo ./vps/install.sh
```

Installs, in order: dependencies (`iptables` before K3s), K3s from the configuration files,
host hardening, Helm, namespaces, credentials and Secrets, NGINX Gateway Fabric,
cert-manager and the Let's Encrypt ClusterIssuers, PostgreSQL, the Keycloak database and
Keycloak (`apply-keycloak.sh`), Prometheus, Grafana, Loki, Alloy, Sealed Secrets,
Argo CD with the Image Updater and the GitOps configuration (`apply-config.sh`), the backup
CronJobs (`apply-backups.sh`) and the NetworkPolicies.
It takes no argument; its environment variables:

| Variable                                                                                                                                                                                                              | Default               | Effect                                                  |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------|---------------------------------------------------------|
| `K3S_VERSION`, `*_CHART_VERSION`, `NGINX_GATEWAY_FABRIC_VERSION`, `CERT_MANAGER_VERSION`                                                                                                                              | `config/versions.env` | versions                                                |
| `INSTALL_FIREWALL`                                                                                                                                                                                                    | `true`                | run `harden-host.sh --apply` (UFW)                      |
| `AUTO_UPDATES`                                                                                                                                                                                                        | `true`                | unattended security updates                             |
| `ALLOW_API_FROM`                                                                                                                                                                                                      | empty                 | space-separated CIDRs allowed on 6443                   |
| `INSTALL_CERT_MANAGER`, `INSTALL_POSTGRESQL`, `INSTALL_KEYCLOAK`, `INSTALL_PROMETHEUS`, `INSTALL_GRAFANA`, `INSTALL_LOKI`, `INSTALL_ALLOY`, `INSTALL_SEALED_SECRETS`, `INSTALL_ARGOCD`, `INSTALL_NETWORK_POLICIES` | `true`                | `false` skips the component (Keycloak needs PostgreSQL) |

When K3s is already installed, its configuration is left untouched (reinstall to change it).
The old `INSTALL_PROMTAIL` flag remains a fallback for `INSTALL_ALLOY`; the new flag takes
precedence. A running Promtail release must be migrated explicitly before installing Alloy:
see [observability migration](docs/observability.md#notes-for-vps-upgrades).

### `uninstall.sh`

```text
sudo ./vps/uninstall.sh [--all] [--k3s] [--helm] [--keep-secrets] [--force]
```

| Option           | Effect                                                                                                                                                                  |
|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| (none)           | removes the platform: Helm releases, Keycloak, Gateway, Argo CD projects, ClusterIssuers, CoreDNS hairpin, application and infrastructure namespaces; K3s keeps running |
| `--k3s`          | uninstalls K3s itself: datastore, volumes (PostgreSQL data and local backups included), `/etc/rancher/k3s`                                                              |
| `--helm`         | removes the Helm binary                                                                                                                                                 |
| `--all`          | `--k3s` and `--helm`: full reinstallation                                                                                                                               |
| `--keep-secrets` | keeps `/root/.k3s-secrets` (removed by default)                                                                                                                         |
| `--force`        | no confirmation prompt                                                                                                                                                  |

Always kept: `/var/backups/k3s-stack`, the UFW rules, the SSH and APT hardening. Both
modes delete the PostgreSQL data and its local dumps (volumes of the namespace `storage`):
the script warns when no off-site copy is configured, or when its credentials (`/root/.k3s-secrets/offsite-backup.env`)
are about to be removed. Before `--k3s`, it
warns when no Sealed Secrets key backup exists.

### `scripts/apply-config.sh`

```text
[sudo] ./vps/scripts/apply-config.sh [--check | --dry-run]
```

Validates `config.env`, then renders and applies the Argo CD ApplicationSets
(`templates/argocd/applicationsets.yaml.tpl`, one generator per organization of
`SCM_ORGANIZATIONS`: `templates/argocd/generator-{alpha,prod}.yaml.tpl`), the Image
Updater CRs and the emptied `default` project (`manifests/argocd-default-project.yaml`).
Each Application belongs to the AppProject of its application, created by
`onboard-app.sh`; Argo CD creates neither projects nor namespaces. The script lists the
Applications left in `default`, refused until their application is onboarded. Run again
after changing `SCM_ORGANIZATIONS`, `REGISTRY_HOST` or `REGISTRY_BASE`.

| Option      | Effect                                       |
|-------------|----------------------------------------------|
| `--check`   | validates `config.env` only (no root needed) |
| `--dry-run` | prints the rendered manifests                |

Applications per onboarded repository holding `helm/<repository>/`: `<repository>-prod`
(branch `main`, image `<image path>/<repository>`, tags `main-<sha>`, manual sync) for
every repository whose default branch holds `helm/`, and `<repository>-alpha` (branch
`develop`, tags `develop-<sha>`, automated sync) only when the repository has a `develop`
branch holding `helm/`. A chart must not hold cluster-scoped resources (Namespace,
ClusterRole, CRD...) nor `ResourceQuota`, `LimitRange`, `Endpoints` or `EndpointSlice`:
its AppProject refuses them.

### `scripts/apply-keycloak.sh`

```text
sudo ./vps/scripts/apply-keycloak.sh [--dry-run] [--no-restart]
```

Renders Keycloak (`templates/keycloak/`) with the extension images of
`KEYCLOAK_EXTENSION_IMAGES`, applies it, restarts Keycloak and waits until it is ready (logins unavailable for 1 to 2
minutes). Run again after changing the images. Called by
`install.sh` with `--no-restart`.

| Option         | Effect                                                    |
|----------------|-----------------------------------------------------------|
| `--dry-run`    | prints the rendered manifest (no root needed)             |
| `--no-restart` | applies only: Keycloak restarts when the manifest changed |

#### Keycloak extension images

Each image of `KEYCLOAK_EXTENSION_IMAGES` runs as an initContainer at every Keycloak start (Pod Security `restricted`:
UID 1000, read-only root filesystem, no capability). Contract:

- `sh` and `cp` available (a `busybox` base is enough), runnable as a non-root user;
- themes under `/themes/<theme-name>/` (login, email, account...), copied into
  `/opt/keycloak/themes`;
- provider JARs under `/providers/` (optional), copied into `/opt/keycloak/providers`;
- a tag or a digest in the reference, never `latest`: a tag is pulled once per node (`IfNotPresent`), so a new version
  needs a new tag, then `apply-keycloak.sh`.

Images are copied in their order (a later image overwrites the files of an earlier one).
Keycloak runs `start` without `--optimized`: it rebuilds itself at startup when the build
options or the providers changed, so providers need no custom Keycloak image. A provider JAR
runs with the full rights of Keycloak (database, credentials): only use trusted images.
Private images are pulled with the Secret `security/ghcr-secret`, created by
`export-secrets.sh set-registry-credentials`.

### `scripts/apply-backups.sh`

```text
[sudo] ./vps/scripts/apply-backups.sh [--dry-run]
```

Installs or upgrades the backup chart (`postgres-backup/`, namespace `storage`): the daily,
weekly and monthly dumps, plus the off-site restic copy and its weekly check when
`OFFSITE_BACKUP_REPOSITORY` is set (restic version: `RESTIC_VERSION` of
`config/versions.env`). Run again after changing the off-site settings or the chart;
emptying `OFFSITE_BACKUP_REPOSITORY` removes the off-site CronJobs. Called by `install.sh`.
Details: [`docs/postgres-backup.md`](docs/postgres-backup.md).

| Option      | Effect                                                          |
|-------------|-----------------------------------------------------------------|
| `--dry-run` | prints the rendered manifests (`helm template`, no root needed) |

### `scripts/harden-host.sh`

```text
sudo ./vps/scripts/harden-host.sh [--apply] [--yes] [--allow-api-from CIDR]... [--ssh-port PORT]...
                                  [--harden-ssh] [--auto-updates]
```

Dry run by default. Firewall policy: incoming traffic denied, SSH rate limited (6 new
connections per 30 s and address; an `OpenSSH` profile rule, which would bypass the limit,
is removed), 80/443 open, K3s pod and service networks allowed (and forwarded pod
traffic), every existing 6443 rule replaced by the `--allow-api-from` networks only.

| Option                  | Effect                                                                    |
|-------------------------|---------------------------------------------------------------------------|
| `--apply`               | applies the changes                                                       |
| `--yes`, `-y`           | no confirmation prompt                                                    |
| `--allow-api-from CIDR` | opens 6443 to a network, repeatable (default: none, use the SSH tunnel)   |
| `--ssh-port PORT`       | SSH port to allow, repeatable (default: detected with `sshd -T`, else 22) |
| `--harden-ssh`          | key-only logins, no root password (refused when no authorized key exists) |
| `--auto-updates`        | unattended security upgrades, no automatic reboot                         |

Keep a second SSH session open until a new login works after `--harden-ssh`.

### `scripts/setup-gateway-api.sh`

```text
sudo ./vps/scripts/setup-gateway-api.sh [--staging] [--no-tls] [--dry-run]
```

From `GATEWAY_HOSTNAMES`, `AUTH_HOSTNAMES` and `KEYCLOAK_RATE_LIMIT_*`: Gateway
`infrastructure-gateway` (namespace `nginx-gateway`, one HTTP listener reserved to the
redirection and the ACME challenges, and one `https-<hostname>` listener per hostname that
only accepts the HTTPRoutes of the namespaces declared for it), one Let's Encrypt Certificate per hostname (certificates
of removed hostnames are pruned), HTTP to HTTPS redirection, Keycloak routes (HTTPRoute `keycloak`: `/realms`, master
realm answered by the gateway; HTTPRoute
`keycloak-resources`: `/resources`; admin console not routed), the RateLimitPolicy
`keycloak` of the OIDC endpoints (per client address, `429` above the burst, login assets
not limited), and the CoreDNS hairpin (pods resolve the public hostnames to the gateway).
Run again after changing the hostnames or the rate limit.

| Option      | Effect                                                                                           |
|-------------|--------------------------------------------------------------------------------------------------|
| `--staging` | Let's Encrypt staging certificates (untrusted, no rate limit): test first                        |
| `--no-tls`  | HTTP only, no certificate or redirection, every namespace routes any hostname on port 80 (tests) |
| `--dry-run` | prints the rendered manifests (no root needed)                                                   |

Applications attach their HTTPRoutes to the Gateway, from the namespace declared for their
hostname: `parentRefs: [{ name: infrastructure-gateway, namespace: nginx-gateway }]`. A
route of another namespace stays unattached (`NotAllowedByListeners`).

### `scripts/setup-secrets.sh`

```text
sudo ./vps/scripts/setup-secrets.sh <setup | rotate | set-discord-webhook | set-offsite-backup>
```

| Command               | Effect                                                                                                                                                                                                                                                                     |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `setup`               | generates the infrastructure passwords once (`/root/.k3s-secrets/credentials.env`) and creates the Kubernetes Secrets; existing credentials are reused (run by `install.sh`)                                                                                               |
| `rotate`              | new PostgreSQL superuser, Keycloak database and Argo CD admin passwords, then restarts PostgreSQL and Keycloak                                                                                                                                                             |
| `set-discord-webhook` | stores the Discord webhook URL of Alertmanager (hidden input)                                                                                                                                                                                                              |
| `set-offsite-backup`  | stores the off-site backup credentials (hidden input): object storage keys and restic password, in `/root/.k3s-secrets/offsite-backup.env` and the Secret `storage/postgres-backup-offsite`; Enter keeps a saved value, an empty password with nothing saved generates one |

Keep the restic password in a password manager: without it, the off-site backups can never
be decrypted (`export-secrets.sh show offsite-backup` displays it).

The Keycloak and Grafana admin passwords only apply at their first start: change them in
their consoles afterwards.

### `scripts/export-secrets.sh`

```text
sudo ./vps/scripts/export-secrets.sh <command> [arguments]
```

| Command                                | Effect                                                                                                                                                                                                                                                                                                                       |
|----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `show [service]`                       | generated credentials; `service`: `postgres`, `keycloak`, `grafana`, `argocd`, `offsite-backup` or an onboarded application                                                                                                                                                                                                  |
| `export-cert <dest>`                   | Sealed Secrets public certificate, for `kubeseal --cert` on a workstation                                                                                                                                                                                                                                                    |
| `backup-sealing-key [dest]`            | encrypted backup (AES-256, PBKDF2) of the Sealed Secrets private keys, default `/var/backups/k3s-stack/sealed-secrets/`                                                                                                                                                                                                      |
| `restore-sealing-key <file>`           | restores the keys of a backup and restarts the controller                                                                                                                                                                                                                                                                    |
| `fetch-from-k8s <secret> <namespace>`  | decoded content of a Kubernetes Secret                                                                                                                                                                                                                                                                                       |
| `set-scm-credentials <github\|gitlab>` | repository access of Argo CD for every organization of `SCM_ORGANIZATIONS` (hidden token input), in the namespace `argocd` only: credential template `<provider>-repo-creds` (URL prefix `https://<provider>.com/<org>`, or `https://<provider>.com/` for several organizations) and `scm-token` (every discovery generator) |
| `set-registry-credentials`             | read-only image pull access (hidden input): `argocd/ghcr-registry-secret` (Image Updater, copied by `onboard-app.sh`), `security/ghcr-secret` (Keycloak extension images) and the `ghcr-secret` of every application namespace                                                                                               |

`SEALING_KEY_PASSPHRASE` provides the backup passphrase (prompted when unset). Without the
Sealed Secrets key, the SealedSecrets committed in Git can never be decrypted again: copy
every backup off the server.

Two tokens, each one serving every organization, ideally of a machine account that is a
read-only member of the organizations (an organization enforcing SAML SSO must authorize
the tokens):

- the **repository token** stays in the namespace `argocd`. On GitHub, a classic personal
  access token with the scope `repo` (a fine-grained token is limited to a single owner):
  the scope grants the rights of its account, hence read-only for such a machine account;
- the **image pull token** is copied into every application namespace, where any chart of
  the application can read it: it must be read-only. On GitHub, a classic token with the
  single scope `read:packages` (GHCR only accepts classic tokens).

Rotation: run the command again. `set-registry-credentials` replaces the pull token in
every namespace; after `set-scm-credentials`, onboard the applications again to refresh
their repository Secret `repo-<app>`.

### `scripts/onboard-app.sh`

```text
sudo ./vps/scripts/onboard-app.sh <app-name> [--environment all|alpha|prod] [--organization ORG]
                                  [--skip-database]
```

For each environment (`<app>-alpha`, `<app>-prod`): the namespace with its quota, default
limits, Pod Security level (`config/onboarding/<env>.env`: `restricted` for both) and
default NetworkPolicy `k3s-stack-default-ingress` (only the namespace itself, the gateway
and Prometheus open connections to its pods), the PostgreSQL role and database
`<app>-<env>`, closed to the other roles, the Secret `<app>-db` (`host`, `port`,
`database`, `username`, `password`, `url` and `r2dbc-url` with TLS required) and the image
pull Secret `ghcr-secret`, copied from `argocd/ghcr-registry-secret` (after
`set-registry-credentials`). Then the Argo CD repository Secret of `<organization>/<app>`
(after `set-scm-credentials`) and, last, the AppProject `<app>`: Argo CD deploys the
application within 3 minutes.

| Option               | Effect                                                                              |
|----------------------|-------------------------------------------------------------------------------------|
| `--environment ENV`  | `all` (default), `alpha` or `prod`                                                  |
| `--organization ORG` | organization of the repository, one of `SCM_ORGANIZATIONS` (default: the first one) |
| `--skip-database`    | no role, database or `<app>-db` Secret                                              |

The name `default` is reserved (Argo CD project). Database passwords are saved in
`/root/.k3s-secrets/<app>.env`. Onboarding again is safe: it applies the current templates
and keeps the passwords; an existing role whose password is unknown is never changed. After
a reinstallation, restore that file (or write `<APP>_<ENV>_DB_PASSWORD=...` lines matching
the SealedSecrets of the application) before onboarding.

A cache such as Redis runs in the chart of the application, in its own namespaces: the
default NetworkPolicy already lets the pods of the namespace reach it, and nothing else.
No pipeline gets a cluster token: Argo CD pulls the deployments.

### `scripts/k3s-maintenance.sh`

```text
sudo ./vps/scripts/k3s-maintenance.sh <status | backup | upgrade [--version V] | restore <archive>> [--yes]
```

| Command                 | Effect                                                                                                                                                           |
|-------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `status`                | installed and latest versions, configuration file, secrets encryption, Gateway API CRDs, backups                                                                 |
| `backup`                | cold backup of the datastore, token, credentials and certificates into `/var/backups/k3s-stack/k3s` (K3s stopped ~10 s, workloads keep running, 5 archives kept) |
| `upgrade [--version V]` | backup, then upgrade to the latest patch of the next minor (or of the current minor when it is the latest stable one); one minor at a time                       |
| `restore <archive>`     | restores an archive with its K3s version; the current state is moved aside                                                                                       |

Upgrades require `/etc/rancher/k3s/config.yaml` and no flag in the systemd unit: a cluster
installed otherwise must be reinstalled. A new K3s minor can bring a newer Gateway API
release: check that NGINX Gateway Fabric supports it (`config/versions.env`).

### `scripts/setup-remote.sh` (workstation, bash 3.2+)

```text
./vps/scripts/setup-remote.sh <vps-host> [--user USER] [--port SSH_PORT] [--local-port PORT]
                              [--context NAME] [--direct]
```

Writes `~/.kube/config-<context>` (mode 0600) from the VPS kubeconfig and checks the
access through a temporary SSH tunnel.

| Option              | Default   | Effect                                                                                             |
|---------------------|-----------|----------------------------------------------------------------------------------------------------|
| `--user USER`       | `root`    | SSH user (passwordless sudo needed)                                                                |
| `--port SSH_PORT`   | `22`      | SSH port                                                                                           |
| `--local-port PORT` | `16443`   | local end of the tunnel                                                                            |
| `--context NAME`    | `k3s-vps` | kubeconfig context, cluster and user name                                                          |
| `--direct`          | -         | `https://<vps-host>:6443` without tunnel (requires `harden-host.sh --allow-api-from <your-ip>/32`) |

Then: `ssh -fN -L 16443:127.0.0.1:6443 <user>@<vps-host>` and
`export KUBECONFIG=~/.kube/config-k3s-vps`.

## Access

| Service                | Access                                                                                                              |
|------------------------|---------------------------------------------------------------------------------------------------------------------|
| kubectl, Helm, k9s     | SSH tunnel (`setup-remote.sh`) or `sudo kubectl` on the VPS                                                         |
| Argo CD                | `kubectl port-forward -n argocd svc/argocd-server 8080:80`, user `admin`, password: `export-secrets.sh show argocd` |
| Grafana                | `kubectl port-forward -n monitoring svc/grafana 3000:80`, password: `export-secrets.sh show grafana`                |
| Prometheus             | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80`                                                  |
| Alertmanager           | `kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093`                                          |
| Keycloak admin console | `kubectl port-forward -n security svc/keycloak 8080:80`, then http://localhost:8080/admin                           |
| PostgreSQL             | [`docs/database-admin.md`](docs/database-admin.md)                                                                  |

Port-forwards enter the pod network namespace: the NetworkPolicies do not apply to them.

## Server locations

| Path                                                        | Content                                                                          |
|-------------------------------------------------------------|----------------------------------------------------------------------------------|
| `/etc/rancher/k3s/config.yaml`, `/etc/rancher/k3s/k3s.yaml` | K3s flags, admin kubeconfig (0600)                                               |
| `/var/log/kubernetes/audit/audit.log`                       | API audit log (Secrets at metadata level, 7 days)                                |
| `/root/.k3s-secrets/`                                       | `credentials.env`, `<app>.env`, `offsite-backup.env` (removed by `uninstall.sh`) |
| `/var/backups/k3s-stack/k3s/`                               | K3s datastore backups (`k3s-maintenance.sh`)                                     |
| `/var/backups/k3s-stack/sealed-secrets/`                    | encrypted Sealed Secrets key backups (copy them off the server by hand)          |
| PVC `storage/postgres-backup-pvc`                           | PostgreSQL dumps ([`docs/postgres-backup.md`](docs/postgres-backup.md))          |
| `OFFSITE_BACKUP_REPOSITORY` (object storage)                | encrypted restic copy of the PostgreSQL dumps                                    |

## Checks

```bash
make lint                # ShellCheck on every script (settings: .shellcheckrc)
make helm-test           # Helm lint and template of the repository charts
make helm-external-test  # external VPS/local charts (Helm, Ruby and network required)
make alloy-test          # synthetic Alloy logs and positions (Python 3, Docker, cached image)
```

The external test isolates Helm's configuration, renders without accessing a cluster and
checks key PVCs, selectors, Secret references, CRDs and Alloy permissions. It does not
prove runtime compatibility or a safe upgrade of an existing release.
The Alloy test uses only synthetic data and the cached image `grafana/alloy:v1.21.3`
inside a container without network access.

## Troubleshooting

| Symptom                                           | Check                                                                                                                                                                                                                                                                                                                                                     |
|---------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A script stops with `Error: <file> line N`        | the failing command is printed; fix and run again (scripts are idempotent)                                                                                                                                                                                                                                                                                |
| Gateway without address, sites unreachable        | `kubectl get pods,events -n nginx-gateway` (the data plane needs the `privileged` Pod Security level of the namespace)                                                                                                                                                                                                                                    |
| Certificate pending                               | DNS of the hostname, port 80 reachable: `kubectl describe certificate -n nginx-gateway`, `kubectl get challenges -A`                                                                                                                                                                                                                                      |
| Pods without DNS or Internet access               | `ufw status` must list the `K3s pods (forwarded)` route rules (`harden-host.sh --apply`)                                                                                                                                                                                                                                                                  |
| Application cannot reach PostgreSQL               | namespace label `app.kubernetes.io/managed-by=k3s-stack` (set by `onboard-app.sh`); a new pod is admitted by the NetworkPolicies ~2 s after it starts: connect with retries                                                                                                                                                                               |
| K3s does not start                                | `systemctl status k3s`, `journalctl -u k3s -n 100`                                                                                                                                                                                                                                                                                                        |
| No Application for a repository                   | application not onboarded (`kubectl get appprojects -n argocd`: no project `<repository>`); `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50`: token without access to the organization (`set-scm-credentials`), no `helm/` directory, no `develop` branch (alpha), repository name used in two organizations |
| Sync error `... is not permitted in project`      | the chart holds a cluster-scoped resource or a refused kind (`ResourceQuota`, `LimitRange`, `Endpoints`, `EndpointSlice`), or a resource of another namespace: remove it from the chart                                                                                                                                                                   |
| HTTPRoute not attached (`NotAllowedByListeners`)  | the namespace of the route is not declared for its hostname in `GATEWAY_HOSTNAMES` (`<hostname>=<namespace>`), then `setup-gateway-api.sh`                                                                                                                                                                                                                |
| Pod refused (`violates PodSecurity "restricted"`) | the chart must run as non-root, drop every capability, forbid privilege escalation and set a seccomp profile (`kubectl describe replicaset -n <namespace>`)                                                                                                                                                                                               |
| Keycloak pod `Init:ImagePullBackOff`              | reference of `KEYCLOAK_EXTENSION_IMAGES`; private image: `kubectl get secret ghcr-secret -n security` (`set-registry-credentials`), then `apply-keycloak.sh`                                                                                                                                                                                              |
| Keycloak answers `429`                            | `KEYCLOAK_RATE_LIMIT_RATE` and `KEYCLOAK_RATE_LIMIT_BURST` too low for the clients behind one address: raise them (or `off`), then `setup-gateway-api.sh`; `kubectl describe ratelimitpolicy keycloak -n security`                                                                                                                                        |
| `KubeJobFailed` on `postgres-backup-offsite*`     | `kubectl logs -n storage -l app.kubernetes.io/component=offsite --tail=50` (exit code 12: wrong `RESTIC_PASSWORD`; unreachable repository: keys, region, bucket), [`docs/postgres-backup.md`](docs/postgres-backup.md)                                                                                                                                    |

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
   `docs/security-hardening.md`](docs/security-hardening.md), known limits).

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
   [observability migration procedure](docs/observability.md#notes-for-vps-upgrades),
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
