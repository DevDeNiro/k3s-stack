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

# validate_gateway_config: GATEWAY_HOSTNAMES and AUTH_HOSTNAMES of config.env
validate_gateway_config() {
    local host
    validate_hostnames GATEWAY_HOSTNAMES
    validate_hostnames AUTH_HOSTNAMES
    for host in ${AUTH_HOSTNAMES:-}; do
        # shellcheck disable=SC2086  # word splitting of the hostname list
        list_contains "$host" ${GATEWAY_HOSTNAMES:-} \
            || die "AUTH_HOSTNAMES: $host is missing from GATEWAY_HOSTNAMES"
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

# apply_registry_secret <namespace> <name> <server> <username> <token>: image pull
# Secret rendered from templates/secrets/dockerconfig.json.tpl
apply_registry_secret() {
    local namespace="$1" name="$2" auth
    auth=$(printf '%s:%s' "$4" "$5" | base64 | tr -d '\n')
    kubectl create secret generic "$name" --namespace "$namespace" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson=<(render_template "$VPS_TEMPLATES_DIR/secrets/dockerconfig.json.tpl" \
            "REGISTRY_SERVER=$3" "REGISTRY_USERNAME=$4" "REGISTRY_AUTH=$auth") \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
