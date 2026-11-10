#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deploys the reference application coterie-webapp on the local k3d cluster:
#   ../coterie-webapp/helm/coterie-webapp (values-local.yaml), http://coterie.local
# Its image comes from GHCR: the Secret ghcr-secret must exist in the namespace
# (kubectl create secret docker-registry), unless values-local.yaml points to an
# image built locally and loaded with "k3d image import".
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../vps/scripts/lib/common.sh
source "$SCRIPT_DIR/../vps/scripts/lib/common.sh"

CLUSTER_NAME="dev-cluster"
COTERIE_NAMESPACE="coterie-webapp-local"
COTERIE_DATABASE="coterie-webapp-local"
# Client secret of the local Keycloak client of coterie-webapp (its values-local.yaml)
COTERIE_KEYCLOAK_CLIENT_SECRET="local-client-secret-123"

usage() {
    printf '%s\n' \
        "Usage: ./local/deploy-app.sh" \
        "" \
        "Deploys coterie-webapp (${WORKSPACE_DIR}/coterie-webapp) on the k3d cluster" \
        "'${CLUSTER_NAME}': PostgreSQL role and database, Secrets, then the Helm chart" \
        "with values-local.yaml. The image is pulled from GHCR with the Secret" \
        "ghcr-secret of the namespace ${COTERIE_NAMESPACE}."
}

deploy_coterie() {
    local chart="$WORKSPACE_DIR/coterie-webapp/helm/coterie-webapp" password
    step "coterie-webapp"
    [[ -d "$chart" ]] || die "$chart not found"
    [[ -s "$SCRIPT_DIR/postgres_password.txt" ]] || die "local/postgres_password.txt missing: run local/install.sh first"
    password=$(cat "$SCRIPT_DIR/postgres_password.txt")

    kubectl create namespace "$COTERIE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl get secret ghcr-secret -n "$COTERIE_NAMESPACE" >/dev/null 2>&1 \
        || warn "no Secret ghcr-secret in ${COTERIE_NAMESPACE}: the GHCR image cannot be pulled"
    pg_wait_ready 120s
    pg_admin_exec "$VPS_SQL_DIR/ensure-role-database.sql" \
        "role=$COTERIE_DATABASE" "password=$password" "database=$COTERIE_DATABASE" reset_password=false
    apply_secret "$COTERIE_NAMESPACE" coterie-webapp-db "password=$password"
    apply_secret "$COTERIE_NAMESPACE" keycloak-client "client-secret=$COTERIE_KEYCLOAK_CLIENT_SECRET"

    helm dependency build "$chart" >/dev/null
    helm upgrade --install coterie-webapp "$chart" \
        --namespace "$COTERIE_NAMESPACE" \
        -f "$chart/values-local.yaml" \
        --wait --timeout 5m || warn "coterie-webapp is not ready yet: kubectl get pods -n $COTERIE_NAMESPACE"
    ok "coterie-webapp: http://coterie.local (/etc/hosts: 127.0.0.1 coterie.local)"
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) usage; die "unknown option: $1" ;;
    esac
    require_commands k3d kubectl helm
    KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")" || die "k3d cluster $CLUSTER_NAME not found: run local/install.sh"
    export KUBECONFIG

    deploy_coterie
    banner "Applications"
    kubectl get httproutes -A
}

main "$@"
