# k3s-stack on a VPS

A single-node K3s platform for small production workloads: Gateway API routing with
Let's Encrypt certificates, PostgreSQL, Keycloak, Redis, Argo CD GitOps, Sealed
Secrets, metrics, logs and alerts. Everything is installed and operated by the
scripts of this directory.

- Guided first installation: [`docs/vps-deployment.md`](docs/vps-deployment.md)
- Security model and migration of an existing VPS: [`docs/security-hardening.md`](docs/security-hardening.md)
- Workstation access (SSH tunnel, kubectl, k9s): [`docs/workstation-setup.md`](docs/workstation-setup.md)

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

| Path | Content |
|------|---------|
| `config.env` | Site settings (copy of `config.env.example`, not versioned) |
| `config/` | Versions, K3s flags and audit policy, SSH/APT hardening, onboarding sizing, Helm repositories |
| `templates/` | Manifests rendered from `config.env` with `envsubst` (Gateway, certificates, Argo CD, onboarding) |
| `values/` | Helm values of every chart |
| `manifests/` | Static manifests (Keycloak, Redis, NetworkPolicies, Image Updater CRs) |
| `namespaces/` | Infrastructure namespaces and their Pod Security levels |
| `sql/` | psql scripts (roles, databases, password rotation) |
| `postgres-backup/` | Helm chart of the PostgreSQL backup CronJobs |
| `scripts/` | Operation scripts; `scripts/lib/common.sh` is the shared library |

## Components

| Component | Version | Namespace | Exposure |
|-----------|---------|-----------|----------|
| K3s (SQLite datastore, secrets encrypted at rest) | v1.37.2+k3s1 | - | API closed by the firewall, SSH tunnel |
| Gateway API CRDs (shipped with K3s) | v1.6.3 | - | - |
| NGINX Gateway Fabric (hostPorts 80/443) | 2.8.1 | `nginx-gateway` | public entry point |
| cert-manager (Let's Encrypt HTTP-01) | v1.21.3 | `cert-manager` | - |
| PostgreSQL (Bitnami chart, image pinned by digest) | chart 18.12.18, PostgreSQL 18.6 | `storage` | in-cluster, TLS available |
| Keycloak | 26.8.2 | `security` | `/realms` and `/resources` of `AUTH_HOSTNAMES`, master realm blocked |
| Redis | 7 | `database` | in-cluster |
| Argo CD + Image Updater | charts 10.17.1 / 1.4.2 | `argocd` | port-forward |
| Sealed Secrets | chart 2.22.0 | `kube-system` | - |
| Prometheus, Alertmanager, node-exporter, kube-state-metrics | chart 29.47.0 | `monitoring` | port-forward |
| Grafana | chart 10.5.15 | `monitoring` | port-forward |
| Loki + Promtail | charts 7.5.0 / 6.17.1 | `monitoring` | - |
| PostgreSQL backups (daily, weekly, monthly) | `postgres-backup/` | `storage` | - |

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
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
sudo ./vps/scripts/onboard-app.sh <app>

# On the workstation
./vps/scripts/setup-remote.sh <vps-host> --user <ssh-user>
```

## Configuration

### `vps/config.env`

| Variable | Example | Used by |
|----------|---------|---------|
| `SCM_PROVIDER` | `github` (or `gitlab`) | Argo CD repository discovery, `onboard-app.sh` |
| `SCM_ORGANIZATION` | `my-org` | ApplicationSets, repository URLs |
| `REGISTRY_BASE` | `ghcr.io/my-org` | image pull Secrets, Image Updater |
| `LETSENCRYPT_EMAIL` | `admin@example.com` | ClusterIssuers |
| `GATEWAY_HOSTNAMES` | `auth.example.com app.example.com` | one HTTPS listener and certificate per hostname |
| `AUTH_HOSTNAMES` | `auth.example.com` | Keycloak routes (each one also listed in `GATEWAY_HOSTNAMES`) |

`./vps/scripts/apply-config.sh --check` validates the file without root access.

### `vps/config/versions.env`

Every version installed by `install.sh` (and by the local mirror). Each one can be
overridden for a single run: `sudo K3S_VERSION=v1.37.2+k3s1 ./vps/install.sh`.
K3s v1.37 or later is required: it ships the Gateway API CRDs.

### Other configuration files

| File | Effect |
|------|--------|
| `config/k3s/config.yaml` | K3s flags (installed into `/etc/rancher/k3s/config.yaml`, kept across upgrades) |
| `config/k3s/audit-policy.yaml` | Kubernetes audit policy (`/var/log/kubernetes/audit/audit.log`) |
| `config/ssh/10-k3s-stack-hardening.conf` | sshd drop-in of `harden-host.sh --harden-ssh` |
| `config/apt/20auto-upgrades` | unattended upgrades of `harden-host.sh --auto-updates` |
| `config/onboarding/{alpha,prod}.env` | quota and Pod Security level of the application namespaces |
| `config/helm-repositories` | Helm repositories added by `install.sh` |
| `values/postgresql-image.yaml` | PostgreSQL image digest, shared by the server and the backups |

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
Keycloak, Redis, Prometheus, Grafana, Loki, Promtail, Sealed Secrets, Argo CD with the
Image Updater and the GitOps configuration, the backup CronJobs and the NetworkPolicies.
It takes no argument; its environment variables:

| Variable | Default | Effect |
|----------|---------|--------|
| `K3S_VERSION`, `*_CHART_VERSION`, `NGINX_GATEWAY_FABRIC_VERSION`, `CERT_MANAGER_VERSION` | `config/versions.env` | versions |
| `INSTALL_FIREWALL` | `true` | run `harden-host.sh --apply` (UFW) |
| `AUTO_UPDATES` | `true` | unattended security updates |
| `ALLOW_API_FROM` | empty | space-separated CIDRs allowed on 6443 |
| `INSTALL_CERT_MANAGER`, `INSTALL_POSTGRESQL`, `INSTALL_KEYCLOAK`, `INSTALL_REDIS`, `INSTALL_PROMETHEUS`, `INSTALL_GRAFANA`, `INSTALL_LOKI`, `INSTALL_PROMTAIL`, `INSTALL_SEALED_SECRETS`, `INSTALL_ARGOCD`, `INSTALL_NETWORK_POLICIES` | `true` | `false` skips the component (Keycloak needs PostgreSQL) |

When K3s is already installed, its configuration is left untouched (reinstall to change it).

### `uninstall.sh`

```text
sudo ./vps/uninstall.sh [--all] [--k3s] [--helm] [--keep-secrets] [--force]
```

| Option | Effect |
|--------|--------|
| (none) | removes the platform: Helm releases, Keycloak, Redis, Gateway, ClusterIssuers, CoreDNS hairpin, application and infrastructure namespaces; K3s keeps running |
| `--k3s` | uninstalls K3s itself: datastore, volumes (PostgreSQL data and local backups included), `/etc/rancher/k3s` |
| `--helm` | removes the Helm binary |
| `--all` | `--k3s` and `--helm`: full reinstallation |
| `--keep-secrets` | keeps `/root/.k3s-secrets` (removed by default) |
| `--force` | no confirmation prompt |

Always kept: `/var/backups/k3s-stack`, the UFW rules, the SSH and APT hardening. Before
`--k3s`, the script warns when no Sealed Secrets key backup exists.

### `scripts/apply-config.sh`

```text
[sudo] ./vps/scripts/apply-config.sh [--check | --dry-run]
```

Validates `config.env`, then renders and applies the Argo CD ApplicationSets
(`templates/argocd/applicationsets.yaml.tpl`) and the Image Updater CRs. Run again after
changing `SCM_ORGANIZATION` or `REGISTRY_BASE`.

| Option | Effect |
|--------|--------|
| `--check` | validates `config.env` only (no root needed) |
| `--dry-run` | prints the rendered manifests |

### `scripts/harden-host.sh`

```text
sudo ./vps/scripts/harden-host.sh [--apply] [--yes] [--allow-api-from CIDR]... [--ssh-port PORT]...
                                  [--harden-ssh] [--auto-updates]
```

Dry run by default. Firewall policy: incoming traffic denied, SSH rate limited (6 new
connections per 30 s and address; an `OpenSSH` profile rule, which would bypass the limit,
is removed), 80/443 open, K3s pod and service networks allowed (and forwarded pod
traffic), every existing 6443 rule replaced by the `--allow-api-from` networks only.

| Option | Effect |
|--------|--------|
| `--apply` | applies the changes |
| `--yes`, `-y` | no confirmation prompt |
| `--allow-api-from CIDR` | opens 6443 to a network, repeatable (default: none, use the SSH tunnel) |
| `--ssh-port PORT` | SSH port to allow, repeatable (default: detected with `sshd -T`, else 22) |
| `--harden-ssh` | key-only logins, no root password (refused when no authorized key exists) |
| `--auto-updates` | unattended security upgrades, no automatic reboot |

Keep a second SSH session open until a new login works after `--harden-ssh`.

### `scripts/setup-gateway-api.sh`

```text
sudo ./vps/scripts/setup-gateway-api.sh [--staging] [--no-tls] [--dry-run]
```

From `GATEWAY_HOSTNAMES` and `AUTH_HOSTNAMES`: Gateway `infrastructure-gateway`
(namespace `nginx-gateway`, one HTTP listener and one `https-<hostname>` listener per
hostname), one Let's Encrypt Certificate per hostname (certificates of removed hostnames
are pruned), HTTP to HTTPS redirection, Keycloak routes (`/realms`, `/resources`; master
realm answered by the gateway; admin console not routed), and the CoreDNS hairpin (pods
resolve the public hostnames to the gateway). Run again after changing the hostnames.

| Option | Effect |
|--------|--------|
| `--staging` | Let's Encrypt staging certificates (untrusted, no rate limit): test first |
| `--no-tls` | HTTP only, no certificate or redirection (tests) |
| `--dry-run` | prints the rendered manifests (no root needed) |

Applications attach their HTTPRoutes to the Gateway:
`parentRefs: [{ name: infrastructure-gateway, namespace: nginx-gateway }]`.

### `scripts/setup-secrets.sh`

```text
sudo ./vps/scripts/setup-secrets.sh <setup | rotate | set-discord-webhook>
```

| Command | Effect |
|---------|--------|
| `setup` | generates the infrastructure passwords once (`/root/.k3s-secrets/credentials.env`) and creates the Kubernetes Secrets; existing credentials are reused (run by `install.sh`) |
| `rotate` | new PostgreSQL superuser, Keycloak database and Argo CD admin passwords, then restarts PostgreSQL and Keycloak |
| `set-discord-webhook` | stores the Discord webhook URL of Alertmanager (hidden input) |

The Keycloak and Grafana admin passwords only apply at their first start: change them in
their consoles afterwards.

### `scripts/export-secrets.sh`

```text
sudo ./vps/scripts/export-secrets.sh <command> [arguments]
```

| Command | Effect |
|---------|--------|
| `show [service]` | generated credentials; `service`: `postgres`, `keycloak`, `grafana`, `argocd` or an onboarded application |
| `export-cert <dest>` | Sealed Secrets public certificate, for `kubeseal --cert` on a workstation |
| `backup-sealing-key [dest]` | encrypted backup (AES-256, PBKDF2) of the Sealed Secrets private keys, default `/var/backups/k3s-stack/sealed-secrets/` |
| `restore-sealing-key <file>` | restores the keys of a backup and restarts the controller |
| `export-kubeconfig <app> <env> <dest>` | CI/CD kubeconfig created by `onboard-app.sh --with-cicd` |
| `fetch-from-k8s <secret> <namespace>` | decoded content of a Kubernetes Secret |
| `set-scm-credentials <github\|gitlab>` | repository access for Argo CD (hidden token input): `<provider>-repo-creds`, `scm-token` (repository discovery) and `ghcr-registry-secret` (Image Updater) |

`SEALING_KEY_PASSPHRASE` provides the backup passphrase (prompted when unset). Without the
Sealed Secrets key, the SealedSecrets committed in Git can never be decrypted again: copy
every backup off the server.

### `scripts/onboard-app.sh`

```text
sudo ./vps/scripts/onboard-app.sh <app-name> [--environment all|alpha|prod] [--skip-database] [--with-cicd]
```

For each environment (`<app>-alpha`, `<app>-prod`): the namespace with its quota, default
limits and Pod Security level (`config/onboarding/<env>.env`: alpha `baseline`, prod
`restricted`), the PostgreSQL role and database `<app>-<env>`, the Secret `<app>-db`
(`host`, `port`, `database`, `username`, `password`, `url` and `r2dbc-url` with TLS
required), the image pull Secret `ghcr-secret` and the Argo CD repository Secret (after
`set-scm-credentials`).

| Option | Effect |
|--------|--------|
| `--environment ENV` | `all` (default), `alpha` or `prod` |
| `--skip-database` | no role, database or `<app>-db` Secret |
| `--with-cicd` | ServiceAccount `deployer` limited to the namespace and its kubeconfig in `/root/.k3s-secrets/kubeconfigs/` (Argo CD already pulls the deployments) |

Database passwords are saved in `/root/.k3s-secrets/<app>.env`. Onboarding again keeps
them; an existing role whose password is unknown is never changed. After a
reinstallation, restore that file (or write `<APP>_<ENV>_DB_PASSWORD=...` lines matching
the SealedSecrets of the application) before onboarding.

### `scripts/k3s-maintenance.sh`

```text
sudo ./vps/scripts/k3s-maintenance.sh <status | backup | upgrade [--version V] | restore <archive>> [--yes]
```

| Command | Effect |
|---------|--------|
| `status` | installed and latest versions, configuration file, secrets encryption, Gateway API CRDs, backups |
| `backup` | cold backup of the datastore, token, credentials and certificates into `/var/backups/k3s-stack/k3s` (K3s stopped ~10 s, workloads keep running, 5 archives kept) |
| `upgrade [--version V]` | backup, then upgrade to the latest patch of the next minor (or of the current minor when it is the latest stable one); one minor at a time |
| `restore <archive>` | restores an archive with its K3s version; the current state is moved aside |

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

| Option | Default | Effect |
|--------|---------|--------|
| `--user USER` | `root` | SSH user (passwordless sudo needed) |
| `--port SSH_PORT` | `22` | SSH port |
| `--local-port PORT` | `16443` | local end of the tunnel |
| `--context NAME` | `k3s-vps` | kubeconfig context, cluster and user name |
| `--direct` | - | `https://<vps-host>:6443` without tunnel (requires `harden-host.sh --allow-api-from <your-ip>/32`) |

Then: `ssh -fN -L 16443:127.0.0.1:6443 <user>@<vps-host>` and
`export KUBECONFIG=~/.kube/config-k3s-vps`.

## Access

| Service | Access |
|---------|--------|
| kubectl, Helm, k9s | SSH tunnel (`setup-remote.sh`) or `sudo kubectl` on the VPS |
| Argo CD | `kubectl port-forward -n argocd svc/argocd-server 8080:80`, user `admin`, password: `export-secrets.sh show argocd` |
| Grafana | `kubectl port-forward -n monitoring svc/grafana 3000:80`, password: `export-secrets.sh show grafana` |
| Prometheus | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` |
| Alertmanager | `kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093` |
| Keycloak admin console | `kubectl port-forward -n security svc/keycloak 8080:80`, then http://localhost:8080/admin |
| PostgreSQL | [`docs/database-admin.md`](docs/database-admin.md) |

Port-forwards enter the pod network namespace: the NetworkPolicies do not apply to them.

## Server locations

| Path | Content |
|------|---------|
| `/etc/rancher/k3s/config.yaml`, `/etc/rancher/k3s/k3s.yaml` | K3s flags, admin kubeconfig (0600) |
| `/var/log/kubernetes/audit/audit.log` | API audit log (Secrets at metadata level, 7 days) |
| `/root/.k3s-secrets/` | `credentials.env`, `<app>.env`, `kubeconfigs/` (removed by `uninstall.sh`) |
| `/var/backups/k3s-stack/k3s/` | K3s datastore backups (`k3s-maintenance.sh`) |
| `/var/backups/k3s-stack/sealed-secrets/` | encrypted Sealed Secrets key backups |
| PVC `storage/postgres-backup-pvc` | PostgreSQL dumps ([`docs/postgres-backup.md`](docs/postgres-backup.md)) |

## Checks

```bash
make lint       # ShellCheck on every script (settings: .shellcheckrc)
make helm-test  # Helm lint and template of the repository charts
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| A script stops with `Error: <file> line N` | the failing command is printed; fix and run again (scripts are idempotent) |
| Gateway without address, sites unreachable | `kubectl get pods,events -n nginx-gateway` (the data plane needs the `privileged` Pod Security level of the namespace) |
| Certificate pending | DNS of the hostname, port 80 reachable: `kubectl describe certificate -n nginx-gateway`, `kubectl get challenges -A` |
| Pods without DNS or Internet access | `ufw status` must list the `K3s pods (forwarded)` route rules (`harden-host.sh --apply`) |
| Application cannot reach PostgreSQL | namespace label `app.kubernetes.io/managed-by=k3s-stack` (set by `onboard-app.sh`); a new pod is admitted by the NetworkPolicies ~2 s after it starts: connect with retries |
| K3s does not start | `systemctl status k3s`, `journalctl -u k3s -n 100` |
