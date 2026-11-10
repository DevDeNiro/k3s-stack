#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deploys the Helm chart of an application on the local k3d cluster: the local
# counterpart of vps/scripts/onboard-app.sh followed by the Argo CD sync.
#   - namespace <app>-local (label app.kubernetes.io/managed-by=k3s-stack)
#   - PostgreSQL role and database <app>-local and the Secret <app>-db, with the
#     keys of the VPS onboarding (host, port, database, username, password, url,
#     r2dbc-url); password kept in local/<app>_db_password.txt (ignored by git)
#   - helm upgrade --install of the chart with its local values file
# Application-specific Secrets (OIDC client, API keys) belong to the application
# chart. Images: public, built locally and loaded with "k3d image import", or
# pulled with a Secret ghcr-secret created in the namespace.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../vps/scripts/lib/common.sh
source "$SCRIPT_DIR/../vps/scripts/lib/common.sh"

CLUSTER_NAME="dev-cluster"
APP_NAME=""
CHART_DIR=""
VALUES_FILE=""
SKIP_DATABASE=false

usage() {
    printf '%s\n' \
        "Usage: ./local/deploy-app.sh <app-name> [--chart DIR] [--values FILE] [--skip-database]" \
        "" \
        "Deploys the Helm chart of an application on the k3d cluster '${CLUSTER_NAME}'," \
        "in the namespace <app>-local, with its PostgreSQL database and Secret <app>-db." \
        "" \
        "  --chart DIR      chart directory (default: ${WORKSPACE_DIR}/<app>/helm/<app>)" \
        "  --values FILE    values file (default: <chart>/values-local.yaml)" \
        "  --skip-database  no PostgreSQL role, database or <app>-db Secret (static client)"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chart) CHART_DIR="${2:?--chart requires a directory}"; shift ;;
            --values) VALUES_FILE="${2:?--values requires a file}"; shift ;;
            --skip-database) SKIP_DATABASE=true ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "unknown option: $1" ;;
            *)
                [[ -z "$APP_NAME" ]] || die "only one application name"
                APP_NAME="$1"
                ;;
        esac
        shift
    done
    [[ -n "$APP_NAME" ]] || { usage; exit 1; }
    [[ "$APP_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
        || die "application name: lowercase letters, digits and hyphens only"
    CHART_DIR="${CHART_DIR:-$WORKSPACE_DIR/$APP_NAME/helm/$APP_NAME}"
    VALUES_FILE="${VALUES_FILE:-$CHART_DIR/values-local.yaml}"
    [[ -f "$CHART_DIR/Chart.yaml" ]] || die "no Helm chart in $CHART_DIR (--chart DIR)"
    [[ -f "$VALUES_FILE" ]] || die "values file not found: $VALUES_FILE (--values FILE)"
}

# app_password: password of the application role, generated on first use
app_password() {
    local file="$SCRIPT_DIR/${APP_NAME}_db_password.txt"
    if [[ ! -s "$file" ]]; then
        (umask 077; generate_password 32 > "$file")
    fi
    cat "$file"
}

create_namespace() {
    step "Namespace ${NAMESPACE}"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl label namespace "$NAMESPACE" --overwrite >/dev/null \
        app.kubernetes.io/managed-by=k3s-stack "app.kubernetes.io/name=$APP_NAME" app.kubernetes.io/environment=local
    kubectl get secret ghcr-secret -n "$NAMESPACE" >/dev/null 2>&1 \
        || warn "no Secret ghcr-secret in ${NAMESPACE}: private registry images cannot be pulled"
}

create_database() {
    if [[ "$SKIP_DATABASE" == "true" ]]; then
        return 0
    fi
    step "PostgreSQL database ${NAMESPACE}"
    kubectl get statefulset postgresql -n "$PG_NAMESPACE" >/dev/null 2>&1 \
        || die "PostgreSQL is not installed (local/install.sh without --skip-postgres), or use --skip-database"
    local password
    password=$(app_password)
    pg_wait_ready 120s
    # The local password file is the reference: the role password follows it
    pg_admin_exec "$VPS_SQL_DIR/ensure-role-database.sql" \
        "role=$NAMESPACE" "password=$password" "database=$NAMESPACE" reset_password=true
    apply_secret "$NAMESPACE" "${APP_NAME}-db" \
        "host=$PG_SERVICE_HOST" port=5432 "database=$NAMESPACE" "username=$NAMESPACE" "password=$password" \
        "url=jdbc:postgresql://${PG_SERVICE_HOST}:5432/${NAMESPACE}?sslmode=require" \
        "r2dbc-url=r2dbc:postgresql://${PG_SERVICE_HOST}:5432/${NAMESPACE}?sslMode=require"
    ok "Database ${NAMESPACE}, Secret ${APP_NAME}-db"
}

deploy_chart() {
    step "Helm release ${APP_NAME} ($(basename "$VALUES_FILE"))"
    helm dependency build "$CHART_DIR" >/dev/null
    helm upgrade --install "$APP_NAME" "$CHART_DIR" \
        --namespace "$NAMESPACE" \
        -f "$VALUES_FILE" \
        --wait --timeout 5m || warn "${APP_NAME} is not ready yet: kubectl get pods -n $NAMESPACE"
}

print_summary() {
    local hosts
    hosts=$(kubectl get httproutes -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{" "}{end}{end}' 2>/dev/null || true)
    banner "${APP_NAME} deployed in ${NAMESPACE}"
    kubectl get pods,httproutes -n "$NAMESPACE"
    if [[ -n "$hosts" ]]; then
        echo ""
        echo "Hostnames served by the local Gateway: ${hosts}"
        echo "  /etc/hosts (except *.localhost): 127.0.0.1 ${hosts}"
    fi
}

main() {
    parse_args "$@"
    NAMESPACE="${APP_NAME}-local"
    require_commands k3d kubectl helm
    KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")" || die "k3d cluster $CLUSTER_NAME not found: run local/install.sh"
    export KUBECONFIG

    create_namespace
    create_database
    deploy_chart
    print_summary
}

main "$@"
