#!/bin/bash

# Script to convert Ingress Controller from NodePort to LoadBalancer mode
# Use it if you want an exact production parity with cloud providers or to apply specific network restrictions for specific routing
# This provides cleaner URLs without port numbers (e.g., http://service.local instead of http://service.local:30080)

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}  Converting Ingress Controller to LoadBalancer${NC}"
echo -e "${BLUE}===============================================${NC}"

# Check if Ingress Controller exists
if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    echo -e "${RED}Error: Ingress Controller not found.${NC}"
    echo -e "${YELLOW}Please install it first with: ./install.sh${NC}"
    exit 1
fi

# Show current configuration
echo -e "\n${YELLOW}Current Ingress Controller configuration:${NC}"
kubectl get svc ingress-nginx-controller -n ingress-nginx

# Backup current configuration
echo -e "\n${YELLOW}Creating backup of current configuration...${NC}"
kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml > ingress-controller-backup-$(date +%Y%m%d_%H%M%S).yaml
echo -e "${GREEN}✓ Backup saved to ingress-controller-backup-*.yaml${NC}"

# Convert service to LoadBalancer
echo -e "\n${YELLOW}Converting service to LoadBalancer type...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'

# Remove NodePort specifications
echo -e "${YELLOW}Removing NodePort specifications...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='merge' -p='{"spec":{"ports":[{"name":"http","port":80,"protocol":"TCP","targetPort":"http"},{"name":"https","port":443,"protocol":"TCP","targetPort":"https"}]}}'

# Wait for LoadBalancer to be ready
echo -e "\n${YELLOW}Waiting for LoadBalancer to be ready...${NC}"
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s

# Show new configuration
echo -e "\n${GREEN}New Ingress Controller configuration:${NC}"
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Update existing Ingress resources to work with LoadBalancer
echo -e "\n${YELLOW}Updating existing Ingress resources...${NC}"

# Function to check and update ingress if exists
update_ingress_if_exists() {
    local namespace=$1
    local ingress_name=$2

    if kubectl get ingress "$ingress_name" -n "$namespace" >/dev/null 2>&1; then
        echo -e "${YELLOW}  ✓ Found $ingress_name in $namespace${NC}"
        # Force recreate ingress to ensure proper routing
        kubectl delete ingress "$ingress_name" -n "$namespace"
        sleep 2
        # The ingress will be recreated by deploy-ingress.sh if needed
    fi
}

# Check for existing ingress resources
update_ingress_if_exists "security" "keycloak-ingress"
update_ingress_if_exists "monitoring" "grafana-ingress"
update_ingress_if_exists "monitoring" "prometheus-server-ingress"
update_ingress_if_exists "storage" "minio-console-ingress"
update_ingress_if_exists "vault" "vault-ingress"
update_ingress_if_exists "messaging" "kafka-ui-ingress"
update_ingress_if_exists "kubernetes-dashboard" "dashboard-ingress"
update_ingress_if_exists "logging" "kibana-ingress"

# Re-deploy ingress resources with updated configuration
echo -e "\n${YELLOW}Re-deploying Ingress resources for LoadBalancer...${NC}"
if [ -f "deploy-ingress.sh" ]; then
    echo -e "${YELLOW}Running deploy-ingress.sh to recreate Ingress resources...${NC}"
    ./deploy-ingress.sh
else
    echo -e "${YELLOW}deploy-ingress.sh not found, you'll need to recreate Ingress resources manually${NC}"
fi

# Final status check
echo -e "\n${GREEN}===============================================${NC}"
echo -e "${GREEN}  Conversion Complete!${NC}"
echo -e "${GREEN}===============================================${NC}"

echo -e "\n${GREEN}=== Services now accessible via (no port needed): ===${NC}"
echo -e "${GREEN}Keycloak:${NC}        http://keycloak.local"
echo -e "${GREEN}Grafana:${NC}         http://grafana.local"
echo -e "${GREEN}Prometheus:${NC}      http://prometheus.local"
echo -e "${GREEN}MinIO Console:${NC}   http://minio.local"
echo -e "${GREEN}Vault:${NC}           http://vault.local"
echo -e "${GREEN}Kafka UI:${NC}        http://kafka-ui.local"
echo -e "${GREEN}Dashboard:${NC}       http://dashboard.local"
echo -e "${GREEN}Kibana:${NC}          http://kibana.local"

echo -e "\n${YELLOW}=== Alternative access methods (still available): ===${NC}"
echo -e "${YELLOW}Dashboard (secure):${NC}   https://localhost:8443 (via port-forward)"
echo -e "${YELLOW}Kafka clients:${NC}        kubectl port-forward svc/kafka 9092:9092 -n messaging"

echo -e "\n${YELLOW}=== Notes: ===${NC}"
echo -e "• LoadBalancer provides cleaner URLs without port numbers"
echo -e "• k3d simulates LoadBalancer behavior locally"
echo -e "• This configuration matches cloud production environments"
echo -e "• If you experience issues, restore with: kubectl apply -f ingress-controller-backup-*.yaml"

echo -e "\n${BLUE}Verification commands:${NC}"
echo -e "kubectl get svc -n ingress-nginx"
echo -e "kubectl get ingress -A"
echo -e "curl -I http://keycloak.local"

echo -e "\n${GREEN}Conversion completed successfully! 🚀${NC}"