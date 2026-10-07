#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deploy Reference Applications on Local K3d Cluster
# Deploys:
#   1. react-starter-kit (Frontend React on Nginx with Gateway API HTTPRoute)
#   2. coterie-webapp (Backend Spring Boot / Kotlin with Gateway API HTTPRoute)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR="$(dirname "$STACK_ROOT")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEPLOY_REACT=true
DEPLOY_COTERIE=true

show_help() {
    cat <<EOF
Usage: ./deploy-app.sh [OPTIONS]

Options:
  --react-only          Deploy only react-starter-kit (Frontend)
  --coterie-only        Deploy only coterie-webapp (Backend)
  --all                 Deploy both applications (Default)
  -h, --help            Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --react-only)
            DEPLOY_REACT=true
            DEPLOY_COTERIE=false
            shift
            ;;
        --coterie-only)
            DEPLOY_REACT=false
            DEPLOY_COTERIE=true
            shift
            ;;
        --all)
            DEPLOY_REACT=true
            DEPLOY_COTERIE=true
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

# Ensure context is local
kubectl config use-context k3d-dev-cluster >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 1. Deploy react-starter-kit (Frontend)
# -----------------------------------------------------------------------------
if [ "$DEPLOY_REACT" = true ]; then
    echo -e "\n${BLUE}=================================================================${NC}"
    echo -e "${YELLOW}>>> Deploying react-starter-kit (Frontend)...${NC}"
    echo -e "${BLUE}=================================================================${NC}"

    REACT_DIR="$WORKSPACE_DIR/react-starter-kit"
    if [ ! -d "$REACT_DIR" ]; then
        echo -e "${RED}Error: Directory not found: $REACT_DIR${NC}"
    else
        # Check if docker image exists locally or build it
        if ! docker image inspect react-starter-kit:latest >/dev/null 2>&1; then
            echo -e "${YELLOW}Building Docker image react-starter-kit:latest...${NC}"
            docker build -t react-starter-kit:latest "$REACT_DIR"
        else
            echo -e "${GREEN}✓ Docker image react-starter-kit:latest found${NC}"
        fi

        echo -e "${YELLOW}Importing image into k3d dev-cluster...${NC}"
        k3d image import react-starter-kit:latest -c dev-cluster

        echo -e "${YELLOW}Applying Kubernetes manifests (kustomize)...${NC}"
        kubectl apply -k "$REACT_DIR/kube"

        echo -e "${YELLOW}Waiting for react-starter-kit rollout...${NC}"
        kubectl rollout status deployment/react-starter-kit -n ns-react-starter-kit --timeout=120s || true
        echo -e "${GREEN}✓ react-starter-kit deployed! Accessible at: http://react-starter-kit.local${NC}"
    fi
fi

# -----------------------------------------------------------------------------
# 2. Deploy coterie-webapp (Backend)
# -----------------------------------------------------------------------------
if [ "$DEPLOY_COTERIE" = true ]; then
    echo -e "\n${BLUE}=================================================================${NC}"
    echo -e "${YELLOW}>>> Deploying coterie-webapp (Backend)...${NC}"
    echo -e "${BLUE}=================================================================${NC}"

    COTERIE_DIR="$WORKSPACE_DIR/coterie-webapp"
    CHART_DIR="$COTERIE_DIR/helm/coterie-webapp"

    if [ ! -d "$CHART_DIR" ]; then
        echo -e "${RED}Error: Helm chart not found: $CHART_DIR${NC}"
    else
        # Ensure local namespace exists
        kubectl create namespace coterie-webapp-local --dry-run=client -o yaml | kubectl apply -f -

        # Retrieve postgres password
        PG_PASSWORD=$(cat "$SCRIPT_DIR/postgres_password.txt" 2>/dev/null || echo "localdevpassword123")

        # Create database in postgres if not exists
        echo -e "${YELLOW}Ensuring database coterie-webapp-local exists in PostgreSQL...${NC}"
        kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres <<EOSQL 2>/dev/null || true
SELECT 'CREATE DATABASE "coterie-webapp-local"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'coterie-webapp-local')\gexec
GRANT ALL PRIVILEGES ON DATABASE "coterie-webapp-local" TO "coterie-webapp-local";
EOSQL

        # Create required application secrets in target namespace
        echo -e "${YELLOW}Creating secrets in coterie-webapp-local namespace...${NC}"
        kubectl create secret generic coterie-webapp-db -n coterie-webapp-local \
            --from-literal=password="$PG_PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -

        kubectl create secret generic keycloak-client -n coterie-webapp-local \
            --from-literal=client-secret="local-client-secret-123" \
            --dry-run=client -o yaml | kubectl apply -f -

        # Build Helm dependency (common-library)
        echo -e "${YELLOW}Checking Helm dependencies...${NC}"
        helm dependency build "$CHART_DIR" >/dev/null 2>&1 || true

        # Deploy with local values
        echo -e "${YELLOW}Deploying coterie-webapp via Helm...${NC}"
        helm upgrade --install coterie-webapp "$CHART_DIR" \
            --namespace coterie-webapp-local \
            -f "$CHART_DIR/values-local.yaml" \
            --wait --timeout 5m || true

        echo -e "${GREEN}✓ coterie-webapp deployment initiated! Accessible at: http://coterie.local${NC}"
    fi
fi

echo -e "\n${BLUE}=================================================================${NC}"
echo -e "${GREEN}    Applications Deployment Summary                             ${NC}"
echo -e "${BLUE}=================================================================${NC}"
echo -e "HTTPRoutes configured:"
kubectl get httproutes -A
echo -e "\nPods state:"
kubectl get pods -n ns-react-starter-kit 2>/dev/null || true
kubectl get pods -n coterie-webapp-local 2>/dev/null || true
