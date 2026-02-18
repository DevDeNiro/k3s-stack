#!/bin/bash

# Color definitions for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print header
echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}    K3d Cluster Uninstall Script     ${NC}"
echo -e "${BLUE}=======================================${NC}"

# Function to prompt for yes/no confirmation
confirm() {
    local prompt="$1"
    local default="$2"

    if [ "$default" = "Y" ]; then
        local options="[Y/n]"
    else
        local options="[y/N]"
    fi

    read -r -p "$prompt $options: " answer

    if [ -z "$answer" ]; then
        answer="$default"
    fi

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Kill port-forwards if running
echo -e "\n${YELLOW}Checking for running port-forwards...${NC}"
if [ -f dashboard_portforward.pid ]; then
    PID=$(cat dashboard_portforward.pid)
    if ps -p $PID > /dev/null; then
        echo -e "${YELLOW}Killing dashboard port-forward (PID: $PID)${NC}"
        kill $PID || true
    fi
    rm -f dashboard_portforward.pid
fi

# Check other potential port-forwards
pkill -f "kubectl.*port-forward" >/dev/null 2>&1 || true

# Check if we need to delete helm releases manually
echo -e "\n${YELLOW}Checking for installed Helm releases...${NC}"
if command -v helm >/dev/null 2>&1; then
    if confirm "Delete all Helm releases first?" "Y"; then
        echo -e "${YELLOW}Deleting Helm releases...${NC}"

        # Monitor namespace
        echo -e "${YELLOW}Checking monitoring namespace...${NC}"
        if kubectl get namespace monitoring >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Prometheus, Grafana, and AlertManager...${NC}"
            helm uninstall prometheus --namespace monitoring 2>/dev/null || true
            helm uninstall grafana --namespace monitoring 2>/dev/null || true
            helm uninstall alertmanager --namespace monitoring 2>/dev/null || true
            kubectl delete namespace monitoring --grace-period=0 --force 2>/dev/null || true
        fi

        # Logging namespace
        echo -e "${YELLOW}Checking logging namespace...${NC}"
        if kubectl get namespace logging >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Elasticsearch and Kibana...${NC}"
            helm uninstall elasticsearch --namespace logging 2>/dev/null || true
            helm uninstall kibana --namespace logging 2>/dev/null || true
            kubectl delete namespace logging --grace-period=0 --force 2>/dev/null || true
        fi

        # Messaging namespace
        echo -e "${YELLOW}Checking messaging namespace...${NC}"
        if kubectl get namespace messaging >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Kafka...${NC}"
            helm uninstall kafka --namespace messaging 2>/dev/null || true
            kubectl delete namespace messaging --grace-period=0 --force 2>/dev/null || true
        fi

        # Security namespace
        echo -e "${YELLOW}Checking security namespace...${NC}"
        if kubectl get namespace security >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Keycloak...${NC}"
            helm uninstall keycloak --namespace security 2>/dev/null || true
            kubectl delete namespace security --grace-period=0 --force 2>/dev/null || true
        fi

        # Vault namespace
        echo -e "${YELLOW}Checking vault namespace...${NC}"
        if kubectl get namespace vault >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Vault...${NC}"
            helm uninstall vault --namespace vault 2>/dev/null || true
            kubectl delete namespace vault --grace-period=0 --force 2>/dev/null || true
        fi

        # Ingress namespace
        echo -e "${YELLOW}Checking ingress namespace...${NC}"
        if kubectl get namespace ingress >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Ingress Controller and Cert-Manager...${NC}"
            helm uninstall ingress-nginx --namespace ingress 2>/dev/null || true
            helm uninstall cert-manager --namespace ingress 2>/dev/null || true
            kubectl delete namespace ingress --grace-period=0 --force 2>/dev/null || true
        fi

        # Kubernetes Dashboard namespace
        echo -e "${YELLOW}Checking kubernetes-dashboard namespace...${NC}"
        if kubectl get namespace kubernetes-dashboard >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Kubernetes Dashboard...${NC}"
            helm uninstall kubernetes-dashboard --namespace kubernetes-dashboard 2>/dev/null || true
            kubectl delete namespace kubernetes-dashboard --grace-period=0 --force 2>/dev/null || true
        fi

        # Redis namespace
        echo -e "${YELLOW}Checking redis namespace...${NC}"
        if kubectl get namespace redis >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Redis...${NC}"
            helm uninstall redis --namespace redis 2>/dev/null || true
            kubectl delete namespace redis --grace-period=0 --force 2>/dev/null || true
        fi

        # Postgres namespace
        echo -e "${YELLOW}Checking postgres namespace...${NC}"
        if kubectl get namespace postgres >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting PostgreSQL...${NC}"
            helm uninstall postgres --namespace postgres 2>/dev/null || true
            kubectl delete namespace postgres --grace-period=0 --force 2>/dev/null || true
        fi

        echo -e "${GREEN}All Helm releases deleted.${NC}"
    fi
fi

# Delete the cluster
echo -e "\n${YELLOW}Checking for k3d cluster...${NC}"
if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list | grep -q "dev-cluster"; then
        if confirm "Delete k3d cluster 'dev-cluster'?" "Y"; then
            echo -e "${YELLOW}Deleting k3d cluster 'dev-cluster'...${NC}"
            k3d cluster delete dev-cluster
            echo -e "${GREEN}Cluster deleted successfully!${NC}"
        else
            echo -e "${YELLOW}Cluster deletion skipped.${NC}"
        fi
    else
        echo -e "${YELLOW}No k3d cluster 'dev-cluster' found.${NC}"
    fi
else
    echo -e "${RED}k3d command not found. Cannot delete cluster.${NC}"
fi

# Clean up token files
echo -e "\n${YELLOW}Cleaning up token files...${NC}"
for token_file in dashboard_token.txt grafana_password.txt elasticsearch_password.txt keycloak_password.txt; do
    if [ -f "$token_file" ]; then
        echo -e "${YELLOW}Removing $token_file...${NC}"
        rm -f "$token_file"
    fi
done

echo -e "\n${GREEN}Uninstall completed!${NC}"