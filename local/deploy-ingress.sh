#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Configuring Ingress for deployed services ===${NC}"

# Check if Ingress Controller is installed
if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    echo -e "${RED}Error: Ingress Controller not found. Install it first with the main script.${NC}"
    exit 1
fi

# Function to deploy an Ingress if the namespace exists
deploy_ingress_if_namespace_exists() {
    local namespace=$1
    local service_name=$2
    local host=$3
    local port=$4
    local ingress_name="${service_name}-ingress"
    local additional_annotations=$5

    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo -e "${YELLOW}Deploying Ingress for $service_name ($host)...${NC}"

        # Check if service exists
        if kubectl get service "$service_name" -n "$namespace" >/dev/null 2>&1; then
            # Check if Ingress already exists
            if kubectl get ingress "$ingress_name" -n "$namespace" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Ingress $ingress_name already exists${NC}"
                return 0
            fi

            kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $ingress_name
  namespace: $namespace
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    $additional_annotations
spec:
  ingressClassName: nginx
  rules:
  - host: $host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $service_name
            port:
              number: $port
EOF
            echo -e "${GREEN}✓ Ingress $ingress_name created${NC}"
        else
            echo -e "${YELLOW}⚠ Service $service_name not found in $namespace${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Namespace $namespace not found, skipping $service_name${NC}"
    fi
}

deploy_vault_ingress() {
    if kubectl get namespace vault >/dev/null 2>&1; then
        echo -e "${YELLOW}Deploying Ingress for Vault...${NC}"

        if kubectl get service vault -n vault >/dev/null 2>&1; then
            if kubectl get ingress vault-ingress -n vault >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Vault Ingress already exists${NC}"
                return 0
            fi

            kubectl apply -f manifests/vault-ingress.yaml
            echo -e "${GREEN}✓ Ingress vault-ingress created${NC}"
        else
            echo -e "${YELLOW}⚠ Vault service not found in vault namespace${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Vault namespace not found${NC}"
    fi
}

# Deploy Kafka UI Ingress if it exists
deploy_kafka_ui_ingress() {
    if kubectl get namespace messaging >/dev/null 2>&1; then
        if kubectl get deployment kafka-ui -n messaging >/dev/null 2>&1; then
            echo -e "${YELLOW}Deploying Ingress for existing Kafka UI...${NC}"
            kubectl apply -f manifests/kafka-ui-ingress.yaml
            echo -e "${GREEN}✓ Ingress kafka-ui-ingress created inline${NC}"
        fi
    fi
    return 1
}

deploy_kafka_ui() {
    if kubectl get namespace messaging >/dev/null 2>&1; then
        # Check if Kafka UI is already installed
        if kubectl get deployment kafka-ui -n messaging >/dev/null 2>&1; then
            echo -e "${GREEN}Kafka UI already installed, creating Ingress only${NC}"
            deploy_kafka_ui_ingress
            return 0
        fi

        echo -e "${YELLOW}Deploying Kafka UI for cluster visualization...${NC}"

        # Check if Kafka exists
        if kubectl get service kafka -n messaging >/dev/null 2>&1; then
                echo -e "${YELLOW}Applying Kafka UI from manifests/kafka-ui.yaml...${NC}"
                kubectl apply -f manifests/kafka-ui.yaml

            # Wait for deployment
            echo -e "${YELLOW}Waiting for Kafka UI to be ready...${NC}"
            kubectl wait --for=condition=available deployment/kafka-ui -n messaging --timeout=180s || true

            # Create Ingress
            deploy_kafka_ui_ingress

            echo -e "${GREEN}✓ Kafka UI deployed successfully${NC}"
        else
            echo -e "${YELLOW}⚠ Kafka service not found in messaging namespace${NC}"
        fi
    fi
}

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

echo -e "\n${YELLOW}=== Deploying Ingress for standard services ===${NC}"

# Deploy Ingress for standard services
deploy_ingress_if_namespace_exists "security" "keycloak" "keycloak.local" 80
deploy_ingress_if_namespace_exists "monitoring" "grafana" "grafana.local" 80
deploy_ingress_if_namespace_exists "monitoring" "prometheus-server" "prometheus.local" 80
deploy_ingress_if_namespace_exists "monitoring" "alertmanager" "alertmanager.local" 9093
deploy_ingress_if_namespace_exists "storage" "minio-console" "minio.local" 9001
deploy_ingress_if_namespace_exists "logging" "kibana-kibana" "kibana.local" 5601

echo -e "\n${YELLOW}=== Deploying Vault Ingress ===${NC}"
# Deploy Vault Ingress
deploy_vault_ingress

echo -e "\n${YELLOW}=== Deploying Kafka UI ===${NC}"
# Deploy Kafka UI Ingress (automatically if already installed, or ask to install)
if ! deploy_kafka_ui_ingress; then
    # Kafka UI not found, ask if user wants to install it
    if kubectl get namespace messaging >/dev/null 2>&1 && kubectl get service kafka -n messaging >/dev/null 2>&1; then
        if confirm "Kafka found but no Kafka UI. Deploy Kafka UI for cluster visualization?" "Y"; then
            deploy_kafka_ui
        else
            echo -e "${YELLOW}Kafka UI deployment skipped${NC}"
        fi
    fi
fi

echo -e "\n${GREEN}Ingress configuration completed!${NC}"

echo -e "\n${YELLOW}=== Configuring local hosts ===${NC}"
# Configure local hosts if not already done
HOSTS_FILE="/etc/hosts"
DOMAINS=(
    "keycloak.local"
    "grafana.local"
    "prometheus.local"
    "alertmanager.local"
    "minio.local"
    "kibana.local"
    "vault.local"
    "kafka-ui.local"
)

for domain in "${DOMAINS[@]}"; do
    if ! grep -q "127.0.0.1.*$domain" "$HOSTS_FILE"; then
        echo -e "${YELLOW}Adding $domain to hosts file${NC}"
        echo "127.0.0.1 $domain" | sudo tee -a "$HOSTS_FILE" > /dev/null
        echo -e "${GREEN}✓ $domain added${NC}"
    else
        echo -e "${GREEN}✓ $domain already configured${NC}"
    fi
done

echo -e "\n${BLUE}=== Access Information ===${NC}"

# Detect Ingress Controller service type and get NodePorts
SERVICE_TYPE=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.type}')
NODEPORT_HTTP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
NODEPORT_HTTPS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)

echo -e "${YELLOW}Ingress Controller Configuration:${NC}"
echo -e "  Service Type: $SERVICE_TYPE"
echo -e "  HTTP NodePort: $NODEPORT_HTTP"
echo -e "  HTTPS NodePort: $NODEPORT_HTTPS"

echo -e "\n${GREEN}=== Services accessible via Ingress ===${NC}"

# Function to show service URL if service exists
show_service_access() {
    local namespace=$1
    local service_name=$2
    local display_name=$3
    local host=$4

    if kubectl get service "$service_name" -n "$namespace" >/dev/null 2>&1; then
        if [ "$SERVICE_TYPE" = "LoadBalancer" ]; then
            echo -e "${GREEN}✓ $display_name:${NC} http://$host"
        else
            echo -e "${GREEN}✓ $display_name:${NC} http://$host:$NODEPORT_HTTP"
        fi
    else
        echo -e "${YELLOW}⚠ $display_name:${NC} Service not deployed"
    fi
}

show_service_access "security" "keycloak" "Keycloak" "keycloak.local"
show_service_access "monitoring" "grafana" "Grafana" "grafana.local"
show_service_access "monitoring" "prometheus-server" "Prometheus" "prometheus.local"
show_service_access "monitoring" "alertmanager" "AlertManager" "alertmanager.local"
show_service_access "storage" "minio-console" "MinIO Console" "minio.local"
show_service_access "logging" "kibana-kibana" "Kibana" "kibana.local"
show_service_access "vault" "vault" "Vault" "vault.local"
show_service_access "messaging" "kafka-ui" "Kafka UI" "kafka-ui.local"

if [ "$SERVICE_TYPE" = "LoadBalancer" ]; then
    echo -e "\n${YELLOW}LoadBalancer mode detected - using standard ports (80/443)${NC}"
else
    echo -e "\n${YELLOW}NodePort mode detected - using ports $NODEPORT_HTTP (HTTP) and $NODEPORT_HTTPS (HTTPS)${NC}"
    echo -e "${YELLOW}To switch to LoadBalancer mode, run: ./switch-to-loadbalancer.sh${NC}"
fi

echo -e "\n${YELLOW}=== Status Check ===${NC}"
echo -e "${YELLOW}Ingress Controller status:${NC}"
kubectl get svc -n ingress-nginx ingress-nginx-controller --no-headers

echo -e "\n${YELLOW}Deployed Ingresses:${NC}"
kubectl get ingress -A --no-headers 2>/dev/null | grep -v "^$" || echo "No Ingresses found"

echo -e "\n${GREEN}✅ Configuration completed successfully!${NC}"

# Quick connectivity test
if command -v curl >/dev/null 2>&1; then
    echo -e "\n${YELLOW}=== Quick Connectivity Test ===${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$NODEPORT_HTTP" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "404" ]; then
        echo -e "${GREEN}✓ Ingress Controller responding correctly (404 = normal, no default backend)${NC}"
    elif [ "$HTTP_CODE" = "000" ]; then
        echo -e "${RED}✗ Cannot connect to Ingress Controller on port $NODEPORT_HTTP${NC}"
        echo -e "${YELLOW}  Check if the Ingress Controller is running properly${NC}"
    else
        echo -e "${YELLOW}⚠ Ingress Controller responding with HTTP code: $HTTP_CODE${NC}"
    fi
else
    echo -e "\n${YELLOW}curl not available - skipping connectivity test${NC}"
fi

echo -e "\n${BLUE}🌐 Your services should now be accessible via the URLs listed above!${NC}"