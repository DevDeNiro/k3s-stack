#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# K3s Local Cluster Setup on K3d (VPS Mirror Stack)
# Creates a local Kubernetes environment matching the VPS architecture:
# - K3s v1.29 mono-node
# - Gateway API (v1.2.0) with NGINX Gateway Fabric (hostPorts 80/443)
# - Infrastructure Gateway in nginx-gateway namespace
# - GitOps with Argo CD in argocd namespace
# - PostgreSQL in storage namespace (host: postgresql.storage.svc.cluster.local)
# - Redis in database namespace (host: redis.database.svc.cluster.local)
# - Sealed Secrets Controller in kube-system namespace
# - Optional: Keycloak in security namespace, Prometheus/Grafana in monitoring
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default configurations
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"
NGINX_GATEWAY_FABRIC_VERSION="${NGINX_GATEWAY_FABRIC_VERSION:-2.4.1}"
INSTALL_GATEWAY_API=true
INSTALL_POSTGRESQL=true
INSTALL_REDIS=true
INSTALL_SEALED_SECRETS=true
INSTALL_ARGOCD=true
INSTALL_KEYCLOAK=false
INSTALL_MONITORING=false
FORCE_RECREATE=false
AUTO_YES=false

show_help() {
    cat <<EOF
Usage: ./install.sh [OPTIONS]

Options:
  --minimal             Install Core stack: Gateway API, Postgres, Redis, ArgoCD, Sealed Secrets (Default)
  --all                 Install everything including Keycloak and Prometheus/Grafana
  --with-keycloak       Include Keycloak IAM in security namespace (~1GB RAM)
  --with-monitoring     Include Prometheus and Grafana in monitoring namespace
  --skip-argocd         Do not install Argo CD
  --skip-postgres       Do not install PostgreSQL
  --skip-redis          Do not install Redis
  --recreate            Force recreation of k3d cluster 'dev-cluster' if it already exists
  -y, --yes             Non-interactive mode (auto confirm)
  -h, --help            Show this help message

Examples:
  ./install.sh                     # Minimal VPS mirror (lightweight, fast)
  ./install.sh --with-keycloak     # Minimal + Keycloak
  ./install.sh --all               # Full stack with monitoring
EOF
    exit 0
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --minimal)
            INSTALL_KEYCLOAK=false
            INSTALL_MONITORING=false
            shift
            ;;
        --all)
            INSTALL_KEYCLOAK=true
            INSTALL_MONITORING=true
            shift
            ;;
        --with-keycloak)
            INSTALL_KEYCLOAK=true
            shift
            ;;
        --with-monitoring)
            INSTALL_MONITORING=true
            shift
            ;;
        --skip-argocd)
            INSTALL_ARGOCD=false
            shift
            ;;
        --skip-postgres)
            INSTALL_POSTGRESQL=false
            shift
            ;;
        --skip-redis)
            INSTALL_REDIS=false
            shift
            ;;
        --recreate)
            FORCE_RECREATE=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}      K3s Local Cluster Setup (VPS Mirror Stack via K3d)        ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# Check required commands
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}Error: '$1' is not installed or not in PATH.${NC}"
        return 1
    else
        echo -e "${GREEN}✓ $1 found${NC}"
        return 0
    fi
}

echo -e "\n${YELLOW}>>> Checking prerequisites...${NC}"
prereqs_ok=true
for cmd in docker k3d kubectl helm; do
    if ! check_command "$cmd"; then
        prereqs_ok=false
    fi
done

if [ "$prereqs_ok" = false ]; then
    echo -e "${RED}Please install missing tools before continuing.${NC}"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker daemon is not running. Please start Docker Desktop.${NC}"
    exit 1
fi

# 1. K3d Cluster Creation
echo -e "\n${YELLOW}>>> Setting up k3d cluster 'dev-cluster'...${NC}"
cluster_exists=false
if k3d cluster list 2>/dev/null | grep -q "dev-cluster"; then
    cluster_exists=true
fi

if [ "$cluster_exists" = true ]; then
    if [ "$FORCE_RECREATE" = true ]; then
        echo -e "${YELLOW}Deleting existing 'dev-cluster'...${NC}"
        k3d cluster delete dev-cluster
        cluster_exists=false
    else
        echo -e "${GREEN}✓ Cluster 'dev-cluster' already exists.${NC}"
        k3d kubeconfig merge dev-cluster --kubeconfig-switch-context >/dev/null 2>&1 || true
        kubectl config use-context k3d-dev-cluster >/dev/null 2>&1 || true
    fi
fi

if [ "$cluster_exists" = false ]; then
    echo -e "${YELLOW}Creating k3d cluster with k3d-config.yaml...${NC}"
    k3d cluster create --config "$SCRIPT_DIR/k3d-config.yaml"
    k3d kubeconfig merge dev-cluster --kubeconfig-switch-context >/dev/null 2>&1 || true
    kubectl config use-context k3d-dev-cluster >/dev/null 2>&1 || true
fi

echo -e "${GREEN}✓ Connected to context: $(kubectl config current-context)${NC}"

# 2. Setup Helm Repositories
echo -e "\n${YELLOW}>>> Updating Helm repositories...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null 2>&1 || true
if [ "$INSTALL_MONITORING" = true ]; then
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
fi
helm repo update >/dev/null 2>&1
echo -e "${GREEN}✓ Helm repositories updated${NC}"

# 3. Create Namespaces
echo -e "\n${YELLOW}>>> Creating namespaces...${NC}"
kubectl apply -f "$SCRIPT_DIR/manifests/namespaces.yaml"
echo -e "${GREEN}✓ Namespaces created${NC}"

# 4. Gateway API & NGINX Gateway Fabric
if [ "$INSTALL_GATEWAY_API" = true ]; then
    echo -e "\n${YELLOW}>>> Installing Gateway API CRDs (${GATEWAY_API_VERSION})...${NC}"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/referencegrants.gateway.networking.k8s.io --timeout=60s
    echo -e "${GREEN}✓ Gateway API CRDs installed${NC}"

    echo -e "${YELLOW}>>> Installing NGINX Gateway Fabric controller (${NGINX_GATEWAY_FABRIC_VERSION})...${NC}"
    helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
        --version "${NGINX_GATEWAY_FABRIC_VERSION}" \
        --namespace nginx-gateway \
        -f "$SCRIPT_DIR/values/nginx-gateway-fabric.yaml" \
        --wait --timeout 5m

    echo -e "${YELLOW}>>> Applying infrastructure-gateway...${NC}"
    kubectl apply -f "$SCRIPT_DIR/manifests/infrastructure-gateway.yaml"

    echo -e "${GREEN}✓ Gateway API & NGINX Gateway Fabric configured${NC}"
fi

# 5. PostgreSQL in storage namespace
if [ "$INSTALL_POSTGRESQL" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying PostgreSQL in 'storage' namespace...${NC}"
    if [ ! -f "$SCRIPT_DIR/postgres_password.txt" ]; then
        PG_PASSWORD="localdevpassword123"
        echo "$PG_PASSWORD" > "$SCRIPT_DIR/postgres_password.txt"
    else
        PG_PASSWORD=$(cat "$SCRIPT_DIR/postgres_password.txt")
    fi

    helm upgrade --install postgresql bitnami/postgresql \
        --namespace storage \
        --set auth.postgresPassword="$PG_PASSWORD" \
        --set auth.password="$PG_PASSWORD" \
        -f "$SCRIPT_DIR/values/postgresql.yaml" \
        --wait --timeout 5m

    echo -e "${GREEN}✓ PostgreSQL running on postgresql.storage.svc.cluster.local:5432${NC}"
fi

# 6. Redis in database namespace
if [ "$INSTALL_REDIS" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Redis in 'database' namespace...${NC}"
    kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"
    kubectl wait --for=condition=available deployment/redis -n database --timeout=120s
    echo -e "${GREEN}✓ Redis running on redis.database.svc.cluster.local:6379${NC}"
fi

# 7. Sealed Secrets Controller in kube-system
if [ "$INSTALL_SEALED_SECRETS" = true ]; then
    echo -e "\n${YELLOW}>>> Installing Sealed Secrets Controller in kube-system...${NC}"
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace kube-system \
        -f "$SCRIPT_DIR/values/sealed-secrets.yaml" \
        --wait --timeout 3m

    # Export public certificate for sealing secrets locally
    mkdir -p "$SCRIPT_DIR/secrets"
    sleep 5
    SECRET_NAME=$(kubectl get secrets -n kube-system -o name 2>/dev/null | grep sealed-secrets-key | head -1 | cut -d'/' -f2 || true)
    if [ -n "$SECRET_NAME" ]; then
        kubectl get secret -n kube-system "$SECRET_NAME" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$SCRIPT_DIR/secrets/sealed-secrets-pub.pem" 2>/dev/null || true
        echo -e "${GREEN}✓ Sealed Secrets public key saved to local/secrets/sealed-secrets-pub.pem${NC}"
    fi
    echo -e "${GREEN}✓ Sealed Secrets Controller ready${NC}"
fi

# 8. Keycloak in security namespace (optional)
if [ "$INSTALL_KEYCLOAK" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Keycloak in 'security' namespace...${NC}"
    if [ ! -f "$SCRIPT_DIR/keycloak_password.txt" ]; then
        KC_PASSWORD="adminpassword123"
        echo "$KC_PASSWORD" > "$SCRIPT_DIR/keycloak_password.txt"
    else
        KC_PASSWORD=$(cat "$SCRIPT_DIR/keycloak_password.txt")
    fi

    kubectl create secret generic keycloak-secret -n security \
        --from-literal=admin-password="$KC_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic keycloak-db-secret -n security \
        --from-literal=password="$PG_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Ensure keycloak database exists in PostgreSQL
    kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres <<EOF 2>/dev/null || true
SELECT 'CREATE DATABASE keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
EOF

    kubectl apply -f "$SCRIPT_DIR/../vps/manifests/keycloak.yaml"
    echo -e "${GREEN}✓ Keycloak deployed in 'security' namespace${NC}"
fi

# 9. Argo CD in argocd namespace (GitOps)
if [ "$INSTALL_ARGOCD" = true ]; then
    echo -e "\n${YELLOW}>>> Installing Argo CD (GitOps)...${NC}"
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        -f "$SCRIPT_DIR/values/argocd.yaml" \
        --wait --timeout 5m

    # Retrieve admin password
    sleep 3
    ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true)
    if [ -n "$ARGO_PASSWORD" ]; then
        echo "$ARGO_PASSWORD" > "$SCRIPT_DIR/argocd_password.txt"
        echo -e "${GREEN}✓ Argo CD initial admin password saved to local/argocd_password.txt${NC}"
    fi
    echo -e "${GREEN}✓ Argo CD installed and running${NC}"
fi

# 10. Monitoring in monitoring namespace (optional)
if [ "$INSTALL_MONITORING" = true ]; then
    echo -e "\n${YELLOW}>>> Installing Prometheus & Grafana...${NC}"
    helm upgrade --install prometheus prometheus-community/prometheus \
        --namespace monitoring \
        --set server.resources.requests.memory="128Mi" \
        --set server.resources.limits.memory="256Mi" \
        --wait --timeout 3m

    helm upgrade --install grafana grafana/grafana \
        --namespace monitoring \
        --set adminPassword="admin" \
        --wait --timeout 3m
    echo -e "${GREEN}✓ Monitoring stack installed${NC}"
fi

# 11. Summary & Instructions
echo -e "\n${BLUE}=================================================================${NC}"
echo -e "${GREEN}    Local K3d VPS Mirror Cluster is READY!                      ${NC}"
echo -e "${BLUE}=================================================================${NC}"
echo -e "Cluster Context : ${YELLOW}k3d-dev-cluster${NC}"
echo -e "Gateway API     : ${YELLOW}infrastructure-gateway${NC} (namespace: ${YELLOW}nginx-gateway${NC}, Port: 80/443)"
echo -e "PostgreSQL      : ${YELLOW}postgresql.storage.svc.cluster.local:5432${NC}"
echo -e "Redis           : ${YELLOW}redis.database.svc.cluster.local:6379${NC}"

if [ "$INSTALL_ARGOCD" = true ]; then
    echo -e "Argo CD UI      : ${YELLOW}kubectl port-forward -n argocd svc/argocd-server 8443:80${NC} -> http://localhost:8443 (admin / $(cat "$SCRIPT_DIR/argocd_password.txt" 2>/dev/null || echo "see argocd-initial-admin-secret"))"
fi

echo -e "\n${YELLOW}To switch between VPS and Local cluster:${NC}"
echo -e "  Local : ${GREEN}kubectl config use-context k3d-dev-cluster${NC}"
echo -e "  VPS   : ${GREEN}kubectl config use-context default${NC}"

echo -e "\n${YELLOW}DNS / Hostname mapping (add to C:\\Windows\\System32\\drivers\\etc\\hosts):${NC}"
echo -e "  127.0.0.1  coterie.local react-starter-kit.local"
