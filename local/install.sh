#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Local mirror of the VPS stack on k3d (macOS or Linux workstation, bash 3.2+)
#
# Same K3s release and flags, Gateway API, GitOps, storage and secret
# controllers as vps/install.sh. Configuration: local/k3d-config.yaml,
# local/manifests, local/values and the shared vps/ files (Keycloak manifest,
# SQL, Keycloak route template).
# Local exceptions: no firewall, no TLS/cert-manager, no audit log; generated
# passwords are kept in local/*_password.txt (ignored by git).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../vps/scripts/lib/common.sh
source "$SCRIPT_DIR/../vps/scripts/lib/common.sh"
# Same versions as the VPS
# shellcheck source=../vps/config/versions.env
source "$VPS_CONFIG_DIR/versions.env"

CLUSTER_NAME="dev-cluster"
LOCAL_AUTH_HOST="auth.localhost"

INSTALL_POSTGRESQL=true
INSTALL_REDIS=true
INSTALL_ARGOCD=true
INSTALL_KEYCLOAK=false
INSTALL_MONITORING=false
FORCE_RECREATE=false

usage() {
    printf '%s\n' \
        "Usage: ./local/install.sh [options]" \
        "" \
        "Creates the k3d cluster '${CLUSTER_NAME}' and installs the VPS mirror stack." \
        "" \
        "  --minimal          Gateway API, PostgreSQL, Redis, Argo CD, Sealed Secrets (default)" \
        "  --all              everything, Keycloak and Prometheus/Grafana included" \
        "  --with-keycloak    Keycloak in namespace security (~1GB RAM), routed on http://${LOCAL_AUTH_HOST}" \
        "  --with-monitoring  Prometheus and Grafana in namespace monitoring" \
        "  --skip-argocd      no Argo CD" \
        "  --skip-postgres    no PostgreSQL (incompatible with Keycloak)" \
        "  --skip-redis       no Redis" \
        "  --recreate         delete and recreate the cluster when it exists" \
        "  -y, --yes          no confirmation prompt (with --recreate)" \
        "  -h, --help         this help"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal) INSTALL_KEYCLOAK=false; INSTALL_MONITORING=false ;;
            --all) INSTALL_KEYCLOAK=true; INSTALL_MONITORING=true ;;
            --with-keycloak) INSTALL_KEYCLOAK=true ;;
            --with-monitoring) INSTALL_MONITORING=true ;;
            --skip-argocd) INSTALL_ARGOCD=false ;;
            --skip-postgres) INSTALL_POSTGRESQL=false ;;
            --skip-redis) INSTALL_REDIS=false ;;
            --recreate) FORCE_RECREATE=true ;;
            -y|--yes) ASSUME_YES=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
    if [[ "$INSTALL_KEYCLOAK" == "true" && "$INSTALL_POSTGRESQL" != "true" ]]; then
        die "Keycloak needs PostgreSQL (remove --skip-postgres)"
    fi
    require_supported_k3s "$K3S_VERSION"
}

# local_password <file>: password stored in local/<file>, generated on first use
local_password() {
    local file="$SCRIPT_DIR/$1"
    if [[ ! -s "$file" ]]; then
        (umask 077; generate_password 24 > "$file")
    fi
    cat "$file"
}

create_cluster() {
    step "k3d cluster ${CLUSTER_NAME}"
    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            confirm "Delete and recreate the cluster ${CLUSTER_NAME}?" || die "aborted"
            k3d cluster delete "$CLUSTER_NAME"
        else
            ok "Cluster ${CLUSTER_NAME} already exists"
        fi
    fi
    if ! k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        # rancher/k3s tags replace the "+" of the K3s release with "-"
        k3d cluster create --config "$SCRIPT_DIR/k3d-config.yaml" --image "rancher/k3s:${K3S_VERSION//+/-}"
    fi
    # Every kubectl/helm call of this script targets the local cluster, whatever KUBECONFIG says
    KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")"
    export KUBECONFIG
    ok "Connected to $(kubectl config current-context)"
    local running
    running=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
    [[ "$running" == "$K3S_VERSION" ]] \
        || warn "the cluster runs K3s ${running}, not ${K3S_VERSION}: --recreate to align it with the VPS"
}

setup_helm_repos() {
    step "Helm repositories"
    local name url
    while read -r name url; do
        helm repo add "$name" "$url" --force-update >/dev/null
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$VPS_CONFIG_DIR/helm-repositories")
    helm repo update >/dev/null
}

# Gateway API CRDs from K3s (gateway-api-crd component), as on the VPS
install_gateway_api() {
    step "NGINX Gateway Fabric ${NGINX_GATEWAY_FABRIC_VERSION}"
    wait_gateway_api_crds
    helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
        --version "$NGINX_GATEWAY_FABRIC_VERSION" \
        --namespace nginx-gateway \
        -f "$SCRIPT_DIR/values/nginx-gateway-fabric.yaml" \
        --wait --timeout 5m
    kubectl apply -f "$SCRIPT_DIR/manifests/infrastructure-gateway.yaml"
}

install_postgresql() {
    [[ "$INSTALL_POSTGRESQL" == "true" ]] || return 0
    step "PostgreSQL (namespace storage)"
    local password
    password=$(local_password postgres_password.txt)
    apply_secret storage postgresql-secret "postgres-password=$password" "password=$password"
    # VPS configuration (TLS, pg_hba, tuning), then the local differences
    helm upgrade --install postgresql bitnami/postgresql \
        --version "$POSTGRESQL_CHART_VERSION" \
        --namespace storage \
        -f "$VPS_VALUES_DIR/postgresql.yaml" \
        -f "$SCRIPT_DIR/values/postgresql.yaml" \
        -f "$VPS_VALUES_DIR/postgresql-image.yaml" \
        --wait --timeout 5m
    ok "PostgreSQL: postgresql.storage.svc.cluster.local:5432"
}

install_redis() {
    [[ "$INSTALL_REDIS" == "true" ]] || return 0
    step "Redis (namespace database)"
    kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"
    kubectl wait --for=condition=available deployment/redis -n database --timeout=120s >/dev/null
}

install_sealed_secrets() {
    step "Sealed Secrets controller"
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --version "$SEALED_SECRETS_CHART_VERSION" \
        --namespace kube-system \
        -f "$SCRIPT_DIR/values/sealed-secrets.yaml" \
        --wait --timeout 3m
    local certificate=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        certificate=$(kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
            --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].data.tls\.crt}' 2>/dev/null)
        [[ -n "$certificate" ]] && break
        sleep 2
    done
    if [[ -n "$certificate" ]]; then
        mkdir -p "$SCRIPT_DIR/secrets"
        printf '%s' "$certificate" | base64 -d > "$SCRIPT_DIR/secrets/sealed-secrets-pub.pem"
        ok "Public certificate: local/secrets/sealed-secrets-pub.pem"
    fi
}

install_keycloak() {
    [[ "$INSTALL_KEYCLOAK" == "true" ]] || return 0
    step "Keycloak (namespace security)"
    local db_password parent_refs hostnames
    db_password=$(local_password postgres_password.txt)
    apply_secret security keycloak-secret "admin-password=$(local_password keycloak_password.txt)"
    apply_secret security keycloak-db-secret "password=$db_password"

    pg_wait_ready 300s
    pg_admin_exec "$VPS_SQL_DIR/ensure-role-database.sql" \
        role=keycloak "password=$db_password" database=keycloak reset_password=true

    kubectl apply -f "$VPS_MANIFESTS_DIR/keycloak.yaml"

    # Same public routes as the VPS (master realm blocked), on the local HTTP listener
    parent_refs=$(render_template "$VPS_TEMPLATES_DIR/gateway/listener-ref.yaml.tpl" LISTENER=http)
    hostnames=$(render_template "$VPS_TEMPLATES_DIR/gateway/hostname-item.yaml.tpl" "HOST=$LOCAL_AUTH_HOST")
    render_template "$VPS_TEMPLATES_DIR/gateway/keycloak-route.yaml.tpl" \
        "PARENT_REFS=$parent_refs" "HOSTNAMES=$hostnames" | kubectl apply -f -

    kubectl rollout status statefulset/keycloak -n security --timeout=600s >/dev/null \
        || warn "Keycloak is still starting: kubectl get pods -n security"
    ok "Keycloak: http://${LOCAL_AUTH_HOST}/realms/<realm> (admin: kubectl port-forward -n security svc/keycloak 8080:80)"
}

install_argocd() {
    [[ "$INSTALL_ARGOCD" == "true" ]] || return 0
    step "Argo CD (namespace argocd)"
    helm upgrade --install argocd argo/argo-cd \
        --version "$ARGOCD_CHART_VERSION" \
        --namespace argocd \
        -f "$SCRIPT_DIR/values/argocd.yaml" \
        --wait --timeout 5m
    local password
    password=$(secret_value argocd argocd-initial-admin-secret password)
    if [[ -n "$password" ]]; then
        (umask 077; printf '%s\n' "$password" > "$SCRIPT_DIR/argocd_password.txt")
        ok "Argo CD admin password: local/argocd_password.txt"
    fi
}

install_monitoring() {
    [[ "$INSTALL_MONITORING" == "true" ]] || return 0
    step "Prometheus and Grafana (namespace monitoring)"
    helm upgrade --install prometheus prometheus-community/prometheus \
        --version "$PROMETHEUS_CHART_VERSION" \
        --namespace monitoring \
        -f "$SCRIPT_DIR/values/prometheus.yaml" \
        --wait --timeout 5m
    helm upgrade --install grafana grafana/grafana \
        --version "$GRAFANA_CHART_VERSION" \
        --namespace monitoring \
        -f "$SCRIPT_DIR/values/grafana.yaml" \
        --wait --timeout 3m
}

print_summary() {
    banner "Local cluster ready"
    echo "Context     : $(kubectl config current-context) (KUBECONFIG=$KUBECONFIG)"
    echo "Gateway     : infrastructure-gateway (namespace nginx-gateway), http://localhost"
    echo "PostgreSQL  : postgresql.storage.svc.cluster.local:5432 (password: local/postgres_password.txt)"
    echo "Redis       : redis.database.svc.cluster.local:6379"
    if [[ "$INSTALL_ARGOCD" == "true" ]]; then
        echo "Argo CD     : kubectl port-forward -n argocd svc/argocd-server 8443:80 -> http://localhost:8443"
    fi
    if [[ "$INSTALL_KEYCLOAK" == "true" ]]; then
        echo "Keycloak    : http://${LOCAL_AUTH_HOST} (admin password: local/keycloak_password.txt)"
    fi
    echo ""
    echo "Reference application: ./local/deploy-app.sh (/etc/hosts: 127.0.0.1 coterie.local)"
}

main() {
    parse_args "$@"
    banner "k3s-stack - local mirror on k3d"
    require_commands docker k3d kubectl helm envsubst
    docker info >/dev/null 2>&1 || die "the Docker daemon is not running"

    create_cluster
    setup_helm_repos
    step "Namespaces"
    kubectl apply -f "$SCRIPT_DIR/manifests/namespaces.yaml"
    install_gateway_api
    install_postgresql
    install_redis
    install_sealed_secrets
    install_keycloak
    install_argocd
    install_monitoring
    print_summary
}

main "$@"
