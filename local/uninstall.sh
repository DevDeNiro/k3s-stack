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
pkill -f "kubectl.*port-forward" >/dev/null 2>&1 || true

# Check if we need to delete helm releases manually
echo -e "\n${YELLOW}Checking for installed Helm releases...${NC}"
if command -v helm >/dev/null 2>&1; then
    if confirm "Delete all Helm releases first?" "Y"; then
        echo -e "${YELLOW}Deleting Helm releases...${NC}"

        # Monitoring namespace
        if kubectl get namespace monitoring >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Prometheus and Grafana...${NC}"
            helm uninstall prometheus --namespace monitoring 2>/dev/null || true
            helm uninstall grafana --namespace monitoring 2>/dev/null || true
            kubectl delete namespace monitoring --grace-period=0 --force 2>/dev/null || true
        fi

        # GitOps / ArgoCD namespace
        if kubectl get namespace argocd >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Argo CD...${NC}"
            helm uninstall argocd --namespace argocd 2>/dev/null || true
            kubectl delete namespace argocd --grace-period=0 --force 2>/dev/null || true
        fi

        # Gateway API / NGINX Gateway Fabric namespace
        if kubectl get namespace nginx-gateway >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting NGINX Gateway Fabric...${NC}"
            helm uninstall nginx-gateway --namespace nginx-gateway 2>/dev/null || true
            kubectl delete namespace nginx-gateway --grace-period=0 --force 2>/dev/null || true
        fi

        # Storage (PostgreSQL)
        if kubectl get namespace storage >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting PostgreSQL...${NC}"
            helm uninstall postgresql --namespace storage 2>/dev/null || true
            kubectl delete namespace storage --grace-period=0 --force 2>/dev/null || true
        fi

        # Database (Redis)
        if kubectl get namespace database >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Redis...${NC}"
            kubectl delete namespace database --grace-period=0 --force 2>/dev/null || true
        fi

        # Security (Keycloak)
        if kubectl get namespace security >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Keycloak...${NC}"
            kubectl delete namespace security --grace-period=0 --force 2>/dev/null || true
        fi

        # Sealed Secrets
        if kubectl get namespace kube-system >/dev/null 2>&1; then
            echo -e "${YELLOW}Deleting Sealed Secrets...${NC}"
            helm uninstall sealed-secrets --namespace kube-system 2>/dev/null || true
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

# Clean up password / token files
echo -e "\n${YELLOW}Cleaning up password files...${NC}"
for token_file in postgres_password.txt argocd_password.txt keycloak_password.txt; do
    if [ -f "$token_file" ]; then
        echo -e "${YELLOW}Removing $token_file...${NC}"
        rm -f "$token_file"
    fi
done

echo -e "\n${GREEN}Uninstall completed!${NC}"