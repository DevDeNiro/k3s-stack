#!/bin/bash
# shellcheck disable=SC2034  # layout and PostgreSQL constants are used by the sourcing scripts
# =============================================================================
# k3s-stack shared helpers: sourced by the vps/ and local/ scripts, never run.
#
# Logic only. Configuration lives in files:
#   vps/config     static host files (K3s, audit policy, SSH, APT, onboarding sizing)
#   vps/manifests  static Kubernetes manifests
#   vps/templates  Kubernetes manifests and text rendered with envsubst (${VAR})
#   vps/values     Helm values
#   vps/sql        psql scripts (psql variables, no inline values)
#
# Bash 3.2 compatible: setup-remote.sh and local/ run on macOS workstations.
# =============================================================================

# -----------------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------------
K3S_STACK_VPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VPS_CONFIG_DIR="$K3S_STACK_VPS_DIR/config"
VPS_MANIFESTS_DIR="$K3S_STACK_VPS_DIR/manifests"
VPS_NAMESPACES_DIR="$K3S_STACK_VPS_DIR/namespaces"
VPS_SQL_DIR="$K3S_STACK_VPS_DIR/sql"
VPS_TEMPLATES_DIR="$K3S_STACK_VPS_DIR/templates"
VPS_VALUES_DIR="$K3S_STACK_VPS_DIR/values"
VPS_CONFIG_FILE="$K3S_STACK_VPS_DIR/config.env"

# Root-only locations on the VPS
SECRETS_DIR="/root/.k3s-secrets"     # generated credentials, removed by uninstall.sh
BACKUP_DIR="/var/backups/k3s-stack"  # backups, kept by uninstall.sh
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# Shared PostgreSQL instance
PG_NAMESPACE="storage"
PG_POD="postgresql-0"
PG_CONTAINER="postgresql"
PG_SERVICE_HOST="postgresql.storage.svc.cluster.local"
PG_ADMIN_SECRET="postgresql-secret"
PG_ADMIN_SECRET_KEY="postgres-password"

# Defaults of the optional config.env settings
DEFAULT_REGISTRY_HOST="ghcr.io"
DEFAULT_KEYCLOAK_RATE_LIMIT_RATE="10r/s"
DEFAULT_KEYCLOAK_RATE_LIMIT_BURST="20"

# Image pull Secrets, all holding the read-only registry token of
# export-secrets.sh set-registry-credentials, never the repository token:
#   - argocd/<REGISTRY_PULL_SECRET>: Argo CD Image Updater
#     (values/argocd-image-updater.yaml), copied by onboard-app.sh
#   - <APP_PULL_SECRET> of each application namespace, referenced by the charts
#   - security/<KEYCLOAK_PULL_SECRET>: private Keycloak extension images
REGISTRY_PULL_SECRET="ghcr-registry-secret"
APP_PULL_SECRET="ghcr-secret"
KEYCLOAK_PULL_SECRET="ghcr-secret"

# Credentials of the off-site backup copy (namespace storage, created by
# setup-secrets.sh set-offsite-backup, read by the postgres-backup chart)
OFFSITE_BACKUP_SECRET="postgres-backup-offsite"

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

banner() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

step() { echo -e "\n${YELLOW}>>> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

# An unexpected failure (set -e) names the failing command instead of exiting
# silently. Main shell only: failures handled by the caller of a command
# substitution or subshell are not reported.
set -o errtrace
trap '[ "${BASH_SUBSHELL:-0}" -eq 0 ] && echo -e "${RED}Error: ${BASH_SOURCE[0]##*/} line ${LINENO}: ${BASH_COMMAND}${NC}" >&2' ERR

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "run this script as root: sudo $0"
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
    done
}

use_k3s_kubeconfig() {
    export KUBECONFIG="$K3S_KUBECONFIG"
}

# k3s_minor <version>: v1.37.2+k3s1 -> 37
k3s_minor() {
    echo "$1" | sed -E 's/^v1\.([0-9]+)\..*/\1/'
}

# require_supported_k3s <version>: K3s ships the Gateway API CRDs since v1.37
require_supported_k3s() {
    local minor
    minor=$(k3s_minor "$1")
    case "$minor" in
        ''|*[!0-9]*) die "K3S_VERSION: '$1' is not a K3s release (v1.37.2+k3s1)" ;;
    esac
    [ "$minor" -ge 37 ] || die "K3s $1 is not supported: v1.37 or later ships the Gateway API CRDs"
}

# -----------------------------------------------------------------------------
# Packages (VPS)
# On a fresh server the apt-daily and unattended-upgrades timers hold the apt
# locks for minutes: wait for them instead of failing.
# -----------------------------------------------------------------------------
APT_LOCK_TIMEOUT=600

# apt_install <package>...: DPkg::Lock::Timeout makes apt-get wait for the dpkg lock
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" install -y -qq "$@"
}

# apt_update: "apt-get update" takes the lists lock, which DPkg::Lock::Timeout does
# not cover (apt 2.8): retried while another apt process holds it, other errors fail
apt_update() {
    local waited=0 err
    while ! err=$(apt-get update -qq 2>&1 >/dev/null); do
        case "$err" in
            *"Could not get lock"*) ;;
            *) printf '%s\n' "$err" >&2; return 1 ;;
        esac
        if [ "$waited" -ge "$APT_LOCK_TIMEOUT" ]; then
            printf '%s\n' "$err" >&2
            return 1
        fi
        sleep 10
        waited=$((waited + 10))
    done
    if [ -n "$err" ]; then
        printf '%s\n' "$err" >&2
    fi
}

# confirm <question>: succeeds when the answer is yes (always with ASSUME_YES=true)
confirm() {
    local answer
    [ "${ASSUME_YES:-false}" = "true" ] && return 0
    read -r -p "$1 [y/N] " answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# vps/config.env
# -----------------------------------------------------------------------------
load_config() {
    [ -f "$VPS_CONFIG_FILE" ] || die "$VPS_CONFIG_FILE not found: cp vps/config.env.example vps/config.env"
    # shellcheck source=/dev/null
    . "$VPS_CONFIG_FILE"
}

# require_config <VAR>...: each variable must be set in config.env
require_config() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || die "$name is not set in $VPS_CONFIG_FILE"
    done
}

# validate_hostnames <VAR>: the variable holds space-separated DNS hostnames
validate_hostnames() {
    local host
    for host in ${!1:-}; do
        echo "$host" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' \
            || die "$1: '$host' is not a valid lowercase hostname"
    done
}

# GATEWAY_HOSTNAMES lists <hostname>=<namespace>[,<namespace>...] entries: the
# namespaces whose HTTPRoutes may attach to the HTTPS listener of the hostname.

# gateway_hosts: the hostnames of GATEWAY_HOSTNAMES, one per line
gateway_hosts() {
    local entry
    for entry in ${GATEWAY_HOSTNAMES:-}; do
        echo "${entry%%=*}"
    done
}

# gateway_host_namespaces <hostname>: namespaces allowed to route it, space-separated
gateway_host_namespaces() {
    local entry
    for entry in ${GATEWAY_HOSTNAMES:-}; do
        if [ "${entry%%=*}" = "$1" ]; then
            echo "${entry#*=}" | tr ',' ' '
            return 0
        fi
    done
}

# validate_gateway_config: GATEWAY_HOSTNAMES and AUTH_HOSTNAMES of config.env
validate_gateway_config() {
    local entry host namespace hosts="" owners
    for entry in ${GATEWAY_HOSTNAMES:-}; do
        case "$entry" in
            ?*=?*) ;;
            *) die "GATEWAY_HOSTNAMES: '$entry' has no namespace: write <hostname>=<namespace>, the namespace allowed to route it (<app>-<env>, or security for Keycloak)" ;;
        esac
        host="${entry%%=*}"
        echo "$host" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' \
            || die "GATEWAY_HOSTNAMES: '$host' is not a valid lowercase hostname"
        # shellcheck disable=SC2086  # word splitting of the hostname list
        if list_contains "$host" $hosts; then
            die "GATEWAY_HOSTNAMES: '$host' is listed twice"
        fi
        hosts="$hosts $host"
        for namespace in $(gateway_host_namespaces "$host"); do
            echo "$namespace" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
                || die "GATEWAY_HOSTNAMES: '$namespace' (hostname $host) is not a valid namespace name"
        done
    done
    validate_hostnames AUTH_HOSTNAMES
    for host in ${AUTH_HOSTNAMES:-}; do
        # shellcheck disable=SC2086  # word splitting of the hostname list
        list_contains "$host" $hosts \
            || die "AUTH_HOSTNAMES: $host is missing from GATEWAY_HOSTNAMES ($host=security)"
        owners=$(gateway_host_namespaces "$host")
        [ "$owners" = "security" ] \
            || die "AUTH_HOSTNAMES: $host belongs to the namespace of Keycloak: $host=security in GATEWAY_HOSTNAMES, not $host=${owners// /,}"
    done
}

# hostname_slug <hostname>: auth.example.com -> auth-example-com
hostname_slug() {
    echo "$1" | tr '.' '-'
}

# list_contains <word> <item>...
list_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# lowercase <text>
lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# -----------------------------------------------------------------------------
# Repositories and images (config.env)
# -----------------------------------------------------------------------------
# scm_organizations: organizations (GitHub) or groups (GitLab) holding the
# application repositories, space-separated: SCM_ORGANIZATIONS, else
# SCM_ORGANIZATION (configuration files written before SCM_ORGANIZATIONS)
scm_organizations() {
    echo "${SCM_ORGANIZATIONS:-${SCM_ORGANIZATION:-}}"
}

# registry_host: registry of the application images (host of REGISTRY_BASE
# when it is set, else REGISTRY_HOST)
registry_host() {
    if [ -n "${REGISTRY_BASE:-}" ]; then
        echo "${REGISTRY_BASE%%/*}"
    else
        echo "${REGISTRY_HOST:-$DEFAULT_REGISTRY_HOST}"
    fi
}

# image_base <organization>: path of the images of an organization, without the
# repository name. REGISTRY_BASE (single organization) takes precedence over
# REGISTRY_HOST/<organization>. The organization is lowercased: registry paths
# are lowercase, while GitHub keeps the case of the organization login.
image_base() {
    if [ -n "${REGISTRY_BASE:-}" ]; then
        echo "$REGISTRY_BASE"
    else
        echo "${REGISTRY_HOST:-$DEFAULT_REGISTRY_HOST}/$(lowercase "$1")"
    fi
}

# validate_scm_config: SCM_PROVIDER, the organizations and the registry settings
validate_scm_config() {
    local pattern org key seen="" count=0
    case "${SCM_PROVIDER:-}" in
        github) pattern='^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' ;;
        gitlab) pattern='^[A-Za-z0-9_.][A-Za-z0-9_.-]*(/[A-Za-z0-9_.][A-Za-z0-9_.-]*)*$' ;;
        *) die "SCM_PROVIDER must be github or gitlab (got: ${SCM_PROVIDER:-})" ;;
    esac
    for org in $(scm_organizations); do
        echo "$org" | grep -Eq "$pattern" \
            || die "SCM_ORGANIZATIONS: '$org' is not a valid ${SCM_PROVIDER} organization name"
        key=$(lowercase "$org")
        # shellcheck disable=SC2086  # word splitting of the list
        if list_contains "$key" $seen; then
            die "SCM_ORGANIZATIONS: '$org' is listed twice"
        fi
        seen="$seen $key"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "SCM_ORGANIZATIONS (or SCM_ORGANIZATION) is not set in $VPS_CONFIG_FILE"

    echo "${REGISTRY_HOST:-$DEFAULT_REGISTRY_HOST}" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?$' \
        || die "REGISTRY_HOST: '${REGISTRY_HOST:-}' is not a lowercase registry host (ghcr.io)"
    if [ -n "${REGISTRY_BASE:-}" ]; then
        [ "$count" -eq 1 ] \
            || die "REGISTRY_BASE only applies to a single organization: remove it, the images are then <REGISTRY_HOST>/<organization>/<repository>"
        echo "$REGISTRY_BASE" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)+$' \
            || die "REGISTRY_BASE: '$REGISTRY_BASE' is not a lowercase registry path (ghcr.io/my-org)"
    fi
}

# validate_image_reference <reference>: lowercase repository path with a tag
# and/or a digest. "latest" is refused: a tag is pulled once per node, so a
# moving tag would never be updated.
validate_image_reference() {
    local name
    echo "$1" | grep -Eq '^([a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?/)?[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127})?(@sha256:[a-f0-9]{64})?$' \
        || return 1
    case "$1" in
        *@sha256:*) return 0 ;;
    esac
    name="${1##*/}"
    case "$name" in
        *:latest) return 1 ;;
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Keycloak (config.env)
# -----------------------------------------------------------------------------
# keycloak_rate_limit_rate, keycloak_rate_limit_burst: gateway rate limit of the
# Keycloak OIDC endpoints, "off" for the rate disables it
keycloak_rate_limit_rate() {
    echo "${KEYCLOAK_RATE_LIMIT_RATE:-$DEFAULT_KEYCLOAK_RATE_LIMIT_RATE}"
}

keycloak_rate_limit_burst() {
    echo "${KEYCLOAK_RATE_LIMIT_BURST:-$DEFAULT_KEYCLOAK_RATE_LIMIT_BURST}"
}

# validate_keycloak_config: KEYCLOAK_EXTENSION_IMAGES and the gateway rate limit
validate_keycloak_config() {
    local image
    for image in ${KEYCLOAK_EXTENSION_IMAGES:-}; do
        validate_image_reference "$image" \
            || die "KEYCLOAK_EXTENSION_IMAGES: '$image' needs a lowercase name and a tag (not latest) or a digest"
    done
    if [ "$(keycloak_rate_limit_rate)" != "off" ]; then
        keycloak_rate_limit_rate | grep -Eq '^[1-9][0-9]*r/[sm]$' \
            || die "KEYCLOAK_RATE_LIMIT_RATE: '$(keycloak_rate_limit_rate)' is not a rate (10r/s, 600r/m) or off"
        keycloak_rate_limit_burst | grep -Eq '^[0-9]+$' \
            || die "KEYCLOAK_RATE_LIMIT_BURST: '$(keycloak_rate_limit_burst)' is not a number of requests"
    fi
}

# -----------------------------------------------------------------------------
# Off-site backups (config.env)
# -----------------------------------------------------------------------------
# validate_offsite_config: OFFSITE_BACKUP_REPOSITORY (restic repository on an
# S3-compatible object storage, optional) and OFFSITE_BACKUP_REGION
validate_offsite_config() {
    [ -n "${OFFSITE_BACKUP_REPOSITORY:-}" ] || return 0
    echo "$OFFSITE_BACKUP_REPOSITORY" | grep -Eq '^s3:(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?/[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](/[A-Za-z0-9._-]+)*/?$' \
        || die "OFFSITE_BACKUP_REPOSITORY: '$OFFSITE_BACKUP_REPOSITORY' is not a restic S3 repository (s3:https://<endpoint>/<bucket>/<path>)"
    if [ -n "${OFFSITE_BACKUP_REGION:-}" ]; then
        echo "$OFFSITE_BACKUP_REGION" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
            || die "OFFSITE_BACKUP_REGION: '$OFFSITE_BACKUP_REGION' is not a region name (fr-par)"
    fi
}

# -----------------------------------------------------------------------------
# Templates
# -----------------------------------------------------------------------------
# render_template <file> <NAME=value | NAME>...: prints the template with only
# the listed variables substituted (NAME alone takes the current value of
# $NAME). Other "$..." and "{{...}}" sequences (Argo CD, Go templates) are left
# untouched. The values reach envsubst through the environment of a subshell:
# never through command arguments, never exported to the rest of the script.
render_template() {
    local template="$1"
    shift
    [ -f "$template" ] || die "template not found: $template"
    require_commands envsubst
    (
        shell_format=""
        for item in "$@"; do
            name="${item%%=*}"
            case "$name" in
                ''|[0-9]*|*[!A-Za-z0-9_]*) die "$(basename "$template"): invalid variable name '$name'" ;;
            esac
            if [ "$name" = "$item" ]; then
                [ -n "${!name+set}" ] || die "$(basename "$template"): variable $name is not set"
                export "${name?}"
            else
                export "${item?}"
            fi
            shell_format="$shell_format \${$name}"
        done
        envsubst "$shell_format" < "$template"
    )
}

# render_keycloak_manifest [image]...: Keycloak StatefulSet and Services
# (templates/keycloak/keycloak.yaml.tpl). Each extension image gets an
# initContainer copying its /themes and /providers into the volumes mounted on
# /opt/keycloak/themes and /opt/keycloak/providers; without image, the
# manifest has no initContainer and no volume.
render_keycloak_manifest() {
    local dir="$VPS_TEMPLATES_DIR/keycloak" image index=0 init_containers="" pod="" container=""
    for image in "$@"; do
        validate_image_reference "$image" \
            || die "Keycloak extension image '$image': lowercase name and a tag (not latest) or a digest"
        index=$((index + 1))
        init_containers="$init_containers$(render_template "$dir/extension-init-container.yaml.tpl" \
            "EXTENSION_NAME=extension-$index" "EXTENSION_IMAGE=$image")"$'\n'
    done
    if [ "$index" -gt 0 ]; then
        pod=$(render_template "$dir/extensions-pod.yaml.tpl" \
            "INIT_CONTAINERS=$init_containers" "PULL_SECRET=$KEYCLOAK_PULL_SECRET")
        container=$(render_template "$dir/extensions-container.yaml.tpl")
    fi
    render_template "$dir/keycloak.yaml.tpl" \
        "KEYCLOAK_POD_EXTENSIONS=$pod" "KEYCLOAK_CONTAINER_EXTENSIONS=$container"
}

# render_keycloak_rate_limit: RateLimitPolicy of the Keycloak HTTPRoute
# (templates/gateway/keycloak-rate-limit.yaml.tpl), from KEYCLOAK_RATE_LIMIT_RATE
# and KEYCLOAK_RATE_LIMIT_BURST
render_keycloak_rate_limit() {
    render_template "$VPS_TEMPLATES_DIR/gateway/keycloak-rate-limit.yaml.tpl" \
        "RATE=$(keycloak_rate_limit_rate)" "BURST=$(keycloak_rate_limit_burst)"
}

# -----------------------------------------------------------------------------
# Secrets
# -----------------------------------------------------------------------------
# generate_password [length]: alphanumeric, safe in YAML, SQL literals and URLs
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "${1:-32}" || true
}

# apply_secret <namespace> <name> <key=value>...: creates or updates a generic
# Secret. Values go through a file descriptor, never through command arguments
# (visible to every local user in the process list).
apply_secret() {
    local namespace="$1" name="$2"
    shift 2
    kubectl create secret generic "$name" --namespace "$namespace" \
        --from-env-file=<(printf '%s\n' "$@") --dry-run=client -o yaml \
        | kubectl apply -f - >/dev/null
}

# apply_dockerconfig_secret <namespace> <name> <dockerconfigjson>: image pull
# Secret holding the given .dockerconfigjson (passed on a file descriptor)
apply_dockerconfig_secret() {
    kubectl create secret generic "$2" --namespace "$1" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson=<(printf '%s' "$3") \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# apply_registry_secret <namespace> <name> <server> <username> <token>: image pull
# Secret rendered from templates/secrets/dockerconfig.json.tpl
apply_registry_secret() {
    local auth
    auth=$(printf '%s:%s' "$4" "$5" | base64 | tr -d '\n')
    apply_dockerconfig_secret "$1" "$2" \
        "$(render_template "$VPS_TEMPLATES_DIR/secrets/dockerconfig.json.tpl" \
            "REGISTRY_SERVER=$3" "REGISTRY_USERNAME=$4" "REGISTRY_AUTH=$auth")"
}

# -----------------------------------------------------------------------------
# Gateway API
# -----------------------------------------------------------------------------
# wait_gateway_api_crds: the Gateway API CRDs are a K3s packaged component
# (HelmChart kube-system/gateway-api-crd, upgraded with K3s itself). Waits until
# the K3s helm-controller has installed them.
wait_gateway_api_crds() {
    local crd version
    for crd in gatewayclasses gateways httproutes referencegrants; do
        for _ in $(seq 1 90); do
            kubectl get crd "${crd}.gateway.networking.k8s.io" >/dev/null 2>&1 && break
            sleep 2
        done
        kubectl wait --for=condition=Established --timeout=60s "crd/${crd}.gateway.networking.k8s.io" >/dev/null \
            || die "Gateway API CRDs missing: kubectl describe helmchart gateway-api-crd -n kube-system"
    done
    version=$(kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
    ok "Gateway API CRDs ${version} (K3s gateway-api-crd component)"
}

# secret_value <namespace> <secret> <key>: decoded value, empty when missing
secret_value() {
    local encoded
    encoded=$(kubectl get secret "$2" -n "$1" \
        -o "go-template={{with index .data \"$3\"}}{{.}}{{end}}" 2>/dev/null) || encoded=""
    if [ -n "$encoded" ]; then
        printf '%s' "$encoded" | base64 -d
    fi
}

# -----------------------------------------------------------------------------
# PostgreSQL
# Secrets never appear in command arguments: the Kubernetes audit log records
# the arguments of every kubectl exec. The password and the psql variables
# travel on stdin; the SQL files read them as :'name'.
# -----------------------------------------------------------------------------
# shellcheck disable=SC2016  # expanded by the shell inside the pod
PG_EXEC_SCRIPT='IFS= read -r PGPASSWORD && export PGPASSWORD && exec psql -X -q -A -t -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d "$2" -f -'

pg_wait_ready() {
    kubectl wait --for=condition=ready "pod/$PG_POD" -n "$PG_NAMESPACE" --timeout="${1:-300s}" >/dev/null
}

# psql_variables <name=value>...: one psql \set line per pair
psql_variables() {
    local pair name value newline=$'\n'
    for pair in "$@"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        case "$value" in
            *"'"*|*\\*|*"$newline"*) die "psql variable $name holds a quote, a backslash or a newline" ;;
        esac
        printf '%s %s %s\n' '\set' "$name" "'$value'"
    done
}

# pg_exec <user> <database> <password> <sql-file> [name=value]...
pg_exec() {
    local user="$1" database="$2" password="$3" sql_file="$4"
    shift 4
    [ -f "$sql_file" ] || die "SQL file not found: $sql_file"
    psql_variables "$@" >/dev/null
    {
        printf '%s\n' "$password"
        psql_variables "$@"
        cat "$sql_file"
    } | kubectl exec -i -n "$PG_NAMESPACE" "$PG_POD" -c "$PG_CONTAINER" -- sh -c "$PG_EXEC_SCRIPT" pg-exec "$user" "$database"
}

# pg_admin_exec <sql-file> [name=value]...: runs the file as the postgres superuser
pg_admin_exec() {
    local sql_file="$1" password
    shift
    password=$(secret_value "$PG_NAMESPACE" "$PG_ADMIN_SECRET" "$PG_ADMIN_SECRET_KEY")
    [ -n "$password" ] || die "PostgreSQL admin password not found (secret $PG_NAMESPACE/$PG_ADMIN_SECRET)"
    pg_exec postgres postgres "$password" "$sql_file" "$@"
}
