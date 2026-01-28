#!/bin/bash
set -euo pipefail

# Change to script directory (repository root) to find files
cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}    K3s Cluster Setup on K3d Installation    ${NC}"
echo -e "${BLUE}===============================================${NC}"

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}Error: $1 is not installed or not in PATH${NC}"
        echo -e "Please install $1 before running this script"
        return 1
    else
        echo -e "${GREEN}✓ $1 is installed${NC}"
        return 0
    fi
}

cleanup_docker() {
    echo -e "${YELLOW}Cleaning up Docker resources...${NC}"
    docker ps -a --filter "name=k3d-dev-cluster" -q | xargs -r docker rm -v -f

    # Remove k3d networks
    docker network ls --filter "name=k3d-dev-cluster" -q | xargs -r docker network rm

    # Prune unused volumes (be careful with this)
    docker volume ls --filter "name=k3d-dev-cluster" -q | xargs -r docker volume rm

    echo -e "${GREEN}Docker cleanup completed${NC}"
}

create_storage_dir() {
    local storage_dir="$HOME/.k3d/storage"
    if [ ! -d "$storage_dir" ]; then
        echo -e "${YELLOW}Creating storage directory: $storage_dir${NC}"
        mkdir -p "$storage_dir"
        chmod 755 "$storage_dir"
    else
        echo -e "${GREEN}Storage directory exists: $storage_dir${NC}"
    fi
}

# Function to install prometheus operator CRDs
install_prometheus_operator_crds() {
    echo -e "\n${YELLOW}>>> Installing Prometheus Operator CRDs...${NC}"

    # Check if CRDs are already installed
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        echo -e "${GREEN}Prometheus Operator CRDs already installed${NC}"
        return 0
    fi

    # Install the CRDs directly from prometheus-operator
    echo -e "${YELLOW}Installing ServiceMonitor CRD...${NC}"
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.2/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

    echo -e "${YELLOW}Installing PrometheusRule CRD...${NC}"
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.2/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml

    echo -e "${YELLOW}Installing Probe CRD...${NC}"
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.2/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml

    echo -e "${YELLOW}Installing PodMonitor CRD...${NC}"
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.2/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml

    # Wait for CRDs to be established
    echo -e "${YELLOW}Waiting for Prometheus Operator CRDs to be established...${NC}"
    kubectl wait --for condition=established --timeout=60s crd/servicemonitors.monitoring.coreos.com
    kubectl wait --for condition=established --timeout=60s crd/prometheusrules.monitoring.coreos.com
    kubectl wait --for condition=established --timeout=60s crd/probes.monitoring.coreos.com
    kubectl wait --for condition=established --timeout=60s crd/podmonitors.monitoring.coreos.com

    echo -e "${GREEN}Prometheus Operator CRDs installed successfully!${NC}"
}

check_service_installed() {
    local service_name="$1"
    local namespace="$2"
    local resource_type="${3:-deployment}"

    if kubectl get "$resource_type" -n "$namespace" 2>/dev/null | grep -q "$service_name"; then
        return 0
    else
        return 1
    fi
}

detect_installed_services() {
    echo -e "\n${YELLOW}Detecting installed services...${NC}"

    # Dashboard
    if check_service_installed "kubernetes-dashboard-api" "kubernetes-dashboard"; then
        echo -e "${GREEN}✓ Kubernetes Dashboard is already installed${NC}"
        dashboard_installed=true
    else
        dashboard_installed=false
    fi

    # PostgreSQL
    if check_service_installed "postgresql" "storage" "statefulset"; then
        echo -e "${GREEN}✓ PostgreSQL is already installed${NC}"
        postgres_installed=true
    else
        postgres_installed=false
    fi

    # Redis
    if check_service_installed "redis" "storage" "statefulset"; then
        echo -e "${GREEN}✓ Redis is already installed${NC}"
        redis_installed=true
    else
        redis_installed=false
    fi

    # Kafka
    if check_service_installed "kafka" "messaging" "statefulset"; then
        echo -e "${GREEN}✓ Kafka is already installed${NC}"
        kafka_installed=true
    else
        kafka_installed=false
    fi

    # Keycloak
    if check_service_installed "keycloak" "security" "statefulset"; then
        echo -e "${GREEN}✓ Keycloak is already installed${NC}"
        keycloak_installed=true
    else
        keycloak_installed=false
    fi

    # Vault
    if check_service_installed "vault" "vault" "statefulset"; then
        echo -e "${GREEN}✓ Vault is already installed${NC}"
        vault_installed=true
    else
        vault_installed=false
    fi

    # Prometheus
    if check_service_installed "prometheus-server" "monitoring"; then
        echo -e "${GREEN}✓ Prometheus is already installed${NC}"
        prometheus_installed=true
    else
        prometheus_installed=false
    fi

    # Grafana
    if check_service_installed "grafana" "monitoring"; then
        echo -e "${GREEN}✓ Grafana is already installed${NC}"
        grafana_installed=true
    else
        grafana_installed=false
    fi

    # Ingress
    if check_service_installed "ingress-nginx-controller" "ingress-nginx"; then
        echo -e "${GREEN}✓ Nginx Ingress is already installed${NC}"
        ingress_installed=true
    else
        ingress_installed=false
    fi

    # MinIO
    if check_service_installed "minio" "storage"; then
        echo -e "${GREEN}✓ MinIO is already installed${NC}"
        minio_installed=true
    else
        minio_installed=false
    fi
}

start_port_forward() {
    echo -e "${YELLOW}Starting port-forward for Kubernetes Dashboard...${NC}"

    # Kill any existing kubectl port-forward process
    pkill -f "kubectl.*port-forward.*kubernetes-dashboard" >/dev/null 2>&1 || true

    # Find the appropriate dashboard service
    echo -e "${YELLOW}Finding appropriate dashboard service...${NC}"
    local dashboard_services
    dashboard_services=$(kubectl get svc -n kubernetes-dashboard -o name | grep -i 'kong\|dashboard')

    if [ -z "$dashboard_services" ]; then
        echo -e "${RED}No dashboard services found in kubernetes-dashboard namespace.${NC}"
        echo -e "${YELLOW}Available services:${NC}"
        kubectl get svc -n kubernetes-dashboard
        return 1
    fi

    # Try to find the Kong proxy service first, as that's the preferred one
    local service_name
    service_name=$(kubectl get svc -n kubernetes-dashboard -o name | grep -i 'kong' | head -1 | sed 's|service/||')

    # If no Kong service, try any dashboard service
    if [ -z "$service_name" ]; then
        service_name=$(kubectl get svc -n kubernetes-dashboard -o name | grep -i 'dashboard' | head -1 | sed 's|service/||')
    fi

    echo -e "${GREEN}Using service: $service_name${NC}"

    # Get target port for the service
    local target_port
    target_port=$(kubectl get svc -n kubernetes-dashboard "$service_name" -o jsonpath='{.spec.ports[0].port}')
    echo -e "${YELLOW}Using target port: $target_port${NC}"

    # Create a dedicated log file for port-forward
    local log_file="dashboard_port_forward.log"
    echo "Starting port-forward at $(date)" > "$log_file"

    # Start port-forward with nohup to ensure it stays running
    nohup kubectl -n kubernetes-dashboard port-forward "svc/$service_name" "8443:$target_port" >> "$log_file" 2>&1 &

    # Save the process ID
    KUBECTL_PF_PID=$!

    # Wait longer to ensure port-forward is established
    echo -e "${YELLOW}Waiting for port-forward to stabilize...${NC}"
    sleep 5

    # check for process status
    if ! ps -p $KUBECTL_PF_PID > /dev/null; then
        echo -e "${RED}Port-forward process failed to start or died immediately.${NC}"
        echo -e "${YELLOW}Port-forward log output:${NC}"
        cat "$log_file"
        return 1
    fi

    # Try to connect to the port to verify it's working
    echo -e "${YELLOW}Testing connection to dashboard...${NC}"
    if command -v curl > /dev/null 2>&1; then
        if curl -s -k -o /dev/null -w "%{http_code}" https://localhost:8443 > /dev/null 2>&1; then
            echo -e "${GREEN}Connection test successful!${NC}"
        else
            echo -e "${YELLOW}Connection test returned non-success code, but process is running.${NC}"
            echo -e "${YELLOW}This may be normal if the dashboard requires authentication.${NC}"
        fi
    else
        echo -e "${YELLOW}curl not found, skipping connection test${NC}"
    fi

    echo -e "${GREEN}Port-forward started successfully. Dashboard accessible at https://localhost:8443${NC}"
    echo -e "${YELLOW}Port-forward logs are in $log_file${NC}"
    echo -e "${YELLOW}To stop port-forward later, run: kill $KUBECTL_PF_PID${NC}"

    # Save PID to file for easy termination later
    echo "$KUBECTL_PF_PID" > dashboard_portforward.pid
    echo -e "${YELLOW}PID saved to dashboard_portforward.pid${NC}"

    return 0
}

copy_token_to_clipboard() {
    local token="$1"

    # Try to detect platform and use appropriate clipboard command
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        echo "$token" | pbcopy
        echo -e "${GREEN}Dashboard token copied to clipboard!${NC}"
    elif command -v xclip > /dev/null 2>&1; then
        # Linux with xclip
        echo "$token" | xclip -selection clipboard
        echo -e "${GREEN}Dashboard token copied to clipboard!${NC}"
    elif command -v wl-copy > /dev/null 2>&1; then
        # Wayland
        echo "$token" | wl-copy
        echo -e "${GREEN}Dashboard token copied to clipboard!${NC}"
    else
        echo -e "${YELLOW}Could not copy to clipboard. No supported clipboard utility found.${NC}"
        return 1
    fi

    return 0
}

# Function to open dashboard in browser
open_dashboard() {
    echo -e "${YELLOW}Attempting to open dashboard in browser...${NC}"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open "https://localhost:8443"
    elif command -v xdg-open > /dev/null 2>&1; then
        # Linux with xdg-open
        xdg-open "https://localhost:8443"
    else
        echo -e "${YELLOW}Could not open browser automatically.${NC}"
        echo -e "${GREEN}Please open https://localhost:8443 in your browser${NC}"
        return 1
    fi

    return 0
}

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"
prerequisites_met=true

# Check required commands
for cmd in kubectl k3d curl docker; do
    if ! check_command "$cmd"; then
        prerequisites_met=false
    fi
done

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    echo -e "Please start Docker and run this script again"
    exit 1
fi

# Additional check for k3d version
if command -v k3d >/dev/null 2>&1; then
    k3d_version=$(k3d version | head -n 1 | cut -d' ' -f3)
    echo -e "  K3d version: ${k3d_version}"
fi

# Exit if prerequisites are not met
if [ "$prerequisites_met" = false ]; then
    echo -e "\n${RED}Please install the missing prerequisites and run the script again.${NC}"
    echo -e "${YELLOW}Installation guides:${NC}"
    echo -e "  K3d: https://k3d.io/#installation"
    echo -e "  kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

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

# Check if cluster already exists and handle it
cluster_exists=false
create_new_cluster=true

if k3d cluster list | grep -q "dev-cluster"; then
    cluster_exists=true
    echo -e "\n${YELLOW}Cluster 'dev-cluster' already exists.${NC}"

    # Show cluster info
    echo -e "${BLUE}Current cluster status:${NC}"
    k3d cluster list | grep dev-cluster || true

    if kubectl config current-context 2>/dev/null | grep -q "k3d-dev-cluster"; then
        echo -e "${GREEN}✓ Cluster is accessible${NC}"
        kubectl get nodes 2>/dev/null || echo -e "${YELLOW}⚠ Cluster not responding${NC}"
    else
        echo -e "${YELLOW}⚠ Cluster context not active${NC}"
    fi

    echo -e "\n${YELLOW}Choose an option:${NC}"
    echo -e "  1) Keep existing cluster and install missing services"
    echo -e "  2) Delete existing cluster and create a fresh one"
    echo -e "  3) Exit without changes"

    read -r -p "Choice [1/2/3]: " cluster_choice

    case $cluster_choice in
        1)
            create_new_cluster=false
            echo -e "${GREEN}Using existing cluster for service installation.${NC}"
            # Ensure we're connected to the existing cluster
            k3d kubeconfig merge dev-cluster --kubeconfig-switch-context || true
            kubectl config use-context k3d-dev-cluster || true

            detect_installed_services
            ;;
        2)
            create_new_cluster=true
            echo -e "${YELLOW}Will delete and recreate cluster.${NC}"
            ;;
        3)
            echo -e "${BLUE}Exiting without changes.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice. Exiting.${NC}"
            exit 1
            ;;
    esac
fi

### SERVICE INSTALLATION ###
echo -e "\n${YELLOW}Select services to install:${NC}"
install_dashboard=false
install_postgres=false
install_redis=false
install_kafka=false
install_keycloak=false
install_vault=false
install_prometheus=false
install_grafana=false
install_elasticsearch=false
install_ingress=false
install_minio=false

# Dashboard
if [ "${dashboard_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Kubernetes Dashboard already installed - skipping${NC}"
    install_dashboard=false
else
    if confirm "Install Kubernetes Dashboard?" "Y"; then
        install_dashboard=true
    fi
fi

# PostgreSQL
if [ "${postgres_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ PostgreSQL already installed - skipping${NC}"
    install_postgres=false
else
    if confirm "Install PostgreSQL (Database)?" "Y"; then
        install_postgres=true
    fi
fi

# Redis
if [ "${redis_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Redis already installed - skipping${NC}"
    install_redis=false
else
    if confirm "Install Redis (Cache/Session Store)?" "Y"; then
        install_redis=true
    fi
fi

# Kafka
if [ "${kafka_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Kafka already installed - skipping${NC}"
    install_kafka=false
else
    if confirm "Install Kafka (Messaging)?" "Y"; then
        install_kafka=true
    fi
fi

# Keycloak
if [ "${keycloak_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Keycloak already installed - skipping${NC}"
    install_keycloak=false
else
    if confirm "Install Keycloak (IAM)?" "Y"; then
        install_keycloak=true
    fi
fi

# Vault
if [ "${vault_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Vault already installed - skipping${NC}"
    install_vault=false
else
    if confirm "Install HashiCorp Vault (Security)?" "Y"; then
        install_vault=true
    fi
fi

# Prometheus
if [ "${prometheus_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Prometheus already installed - skipping${NC}"
    install_prometheus=false
else
    if confirm "Install Prometheus (Monitoring)?" "Y"; then
        install_prometheus=true
    fi
fi

# Grafana
if [ "${grafana_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Grafana already installed - skipping${NC}"
    install_grafana=false
else
    if confirm "Install Grafana (Monitoring Dashboards)?" "Y"; then
        install_grafana=true
    fi
fi

# Elasticsearch
#if confirm "Install Elasticsearch and Kibana (Logging)?" "Y"; then
#    install_elasticsearch=true
#fi

# Ingress
if [ "${ingress_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ Nginx Ingress already installed - skipping${NC}"
    install_ingress=false
else
    if confirm "Install Nginx Ingress Controller ?" "Y"; then
        install_ingress=true
    fi
fi

# MinIO
if [ "${minio_installed:-false}" = true ]; then
    echo -e "${GREEN}✓ MinIO already installed - skipping${NC}"
    install_minio=false
else
    if confirm "Install MinIO (Object Storage)?" "Y"; then
        install_minio=true
    fi
fi

# Handle cluster creation/deletion based on earlier choice
if [ "$create_new_cluster" = true ] && [ "$cluster_exists" = true ]; then
    echo -e "\n${YELLOW}Deleting existing cluster...${NC}"
    k3d cluster delete dev-cluster
    # Additional cleanup
    cleanup_docker
    sleep 3
fi

# Create storage directory if needed
if [ "$create_new_cluster" = true ]; then
    create_storage_dir
fi

# Create the K3d cluster
if [ "$create_new_cluster" = true ]; then
    echo -e "\n${YELLOW}>>> Creating K3d/K3s cluster...${NC}"

    if [ -f k3d-config.yaml ]; then
        echo -e "${YELLOW}Using configuration file: k3d-config.yaml${NC}"
        # Try with config file first
        if ! k3d cluster create --config k3d-config.yaml; then
            echo -e "${RED}Failed to create cluster with config file, trying default configuration...${NC}"
            # Fallback to manual configuration
            k3d cluster create dev-cluster \
                --servers 1 \
                --agents 0 \
                --port "80:80@loadbalancer" \
                --port "443:443@loadbalancer" \
                --port "6443:6443@server:0" \
                --volume "$HOME/.k3d/storage:/var/lib/rancher/k3s/storage@server:0" \
                --k3s-arg "--disable=traefik@server:0" \
                --wait --timeout 120s
        fi
    else
        echo -e "${YELLOW}No config file found, creating cluster with default settings...${NC}"
        k3d cluster create dev-cluster \
            --servers 1 \
            --agents 0 \
            --port "80:80@loadbalancer" \
            --port "443:443@loadbalancer" \
            --port "6443:6443@server:0" \
            --volume "$HOME/.k3d/storage:/var/lib/rancher/k3s/storage@server:0" \
            --k3s-arg "--disable=traefik@server:0" \
            --wait --timeout 120s
    fi

    # Ensure kubeconfig is updated
    echo -e "${YELLOW}Updating kubeconfig...${NC}"
    k3d kubeconfig merge dev-cluster --kubeconfig-switch-context
    kubectl config use-context k3d-dev-cluster

    # Fix potential host.docker.internal issues
    if grep -q "host.docker.internal" ~/.kube/config; then
        echo -e "${YELLOW}Replacing host.docker.internal with 127.0.0.1 in kubeconfig...${NC}"

        # Check if we're on macOS (BSD sed) or Linux (GNU sed)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS version (BSD sed)
            sed -i '' 's/host.docker.internal/127.0.0.1/g' ~/.kube/config
        else
            # Linux version (GNU sed)
            sed -i 's/host.docker.internal/127.0.0.1/g' ~/.kube/config
        fi
    fi

    # Wait for cluster to be ready with extended timeout
    echo -e "${YELLOW}Waiting for cluster to be ready...${NC}"
    timeout=60
    counter=0
    connected=false

    while [ $counter -lt $timeout ]; do
        # First check if kubectl can connect to the API server
        if kubectl get nodes >/dev/null 2>&1; then
            # Then check if at least one node is Ready
            if kubectl get nodes --no-headers | grep -q " Ready "; then
                echo -e "${GREEN}Kubernetes API is accessible and nodes are ready!${NC}"
                connected=true
                break
            fi
        fi
        echo -e "${YELLOW}Waiting for Kubernetes API to become accessible... ($counter/$timeout seconds)${NC}"
        sleep 5
        counter=$((counter + 5))
    done

    if [ "$connected" = false ]; then
        echo -e "${RED}Failed to connect to Kubernetes cluster after $timeout seconds.${NC}"
        echo -e "${YELLOW}Troubleshooting tips:${NC}"
        echo -e "  1. Check Docker status: docker info"
        echo -e "  2. Check k3d cluster status: k3d cluster list"
        echo -e "  3. Check kubernetes context: kubectl config get-contexts"
        echo -e "  4. Try manually: k3d kubeconfig merge dev-cluster --kubeconfig-switch-context"
        exit 1
    fi

    echo -e "${GREEN}Connected to Kubernetes cluster!${NC}"
    kubectl get nodes
fi

# Check and install Helm if needed
echo -e "\n${YELLOW}>>> Checking Helm...${NC}"
if ! check_command helm; then
    echo -e "${YELLOW}Helm not found, installing...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o get_helm.sh
    chmod +x get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
fi

# Install required CRDs if monitoring services are selected
if [ "$install_prometheus" = true ] || [ "$install_grafana" = true ] || [ "$install_minio" = true ] || [ "$install_ingress" = true ]; then
    install_prometheus_operator_crds
fi

### INSTALL RESOURCES ###
echo -e "\n${YELLOW}>>> Configuring Helm repositories...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo add confluentinc https://confluentinc.github.io/cp-helm-charts/
helm repo add keycloak https://codecentric.github.io/helm-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add minio https://charts.min.io/
helm repo update

### Deploy selected Helm charts ###
if [ "$install_postgres" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying PostgreSQL...${NC}"

    # Generate random password for PostgreSQL if not already created
    if [ ! -f postgres_password.txt ]; then
        POSTGRES_PASSWORD=$(openssl rand -base64 12)
        echo "$POSTGRES_PASSWORD" > postgres_password.txt
        chmod 600 postgres_password.txt
    else
        POSTGRES_PASSWORD=$(cat postgres_password.txt)
    fi

    helm install postgresql bitnami/postgresql --namespace storage --create-namespace \
        --set auth.postgresPassword="$POSTGRES_PASSWORD" \
        --set auth.database=myapp \
        --set auth.username=myapp \
        --set auth.password="$POSTGRES_PASSWORD" \
        -f values/postgresql.yaml --wait --timeout 300s

    echo -e "${GREEN}PostgreSQL deployed successfully!${NC}" postgresql-nodeport
    echo -e "${YELLOW}PostgreSQL credentials saved to postgres_password.txt${NC}"

    # kubectl port-forward -n storage svc/postgresql 5432:5432 # to use for local dev
    kubectl apply -f manifests/postgresql-nodeport.yaml
    echo -e "${GREEN}PostgreSQL NodePort service created on port 30432${NC}"
fi

if [ "$install_redis" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Redis...${NC}"

    # Generate random password for Redis if not already created
    if [ ! -f redis_password.txt ]; then
        REDIS_PASSWORD=$(openssl rand -base64 12)
        echo "$REDIS_PASSWORD" > redis_password.txt
        chmod 600 redis_password.txt
    else
        REDIS_PASSWORD=$(cat redis_password.txt)
    fi

    helm install redis bitnami/redis --namespace storage --create-namespace \
        --set auth.password="$REDIS_PASSWORD" \
        -f values/redis.yaml --wait --timeout 120s

    echo -e "${GREEN}Redis deployed successfully!${NC}"
    echo -e "${YELLOW}Redis credentials saved to redis_password.txt${NC}"

    kubectl apply -f manifests/redis-nodeport.yaml
    echo -e "${GREEN}Redis NodePort service created on port 30379${NC}"
fi

if [ "$install_kafka" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Kafka...${NC}"
    helm install kafka bitnami/kafka --namespace messaging --create-namespace \
        -f values/kafka.yaml --wait --timeout 900s
    echo -e "${GREEN}Kafka deployed successfully!${NC}"

    # Wait for Kafka to be fully ready
    echo -e "${YELLOW}Waiting for Kafka to be fully ready...${NC}"
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=kafka -n messaging --timeout=900s

    echo -e "${YELLOW}Verifying Kafka connectivity...${NC}"
    timeout=60
    counter=0
    while [ $counter -lt $timeout ]; do
        if kubectl exec kafka-broker-0 -n messaging -- kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1; then
            echo -e "${GREEN}Kafka is responding to requests!${NC}"
            break
        fi
        echo -e "${YELLOW}Waiting for Kafka to respond... ($counter/$timeout seconds)${NC}"
        sleep 5
        counter=$((counter + 5))
    done

    echo -e "${YELLOW}Verifying external Kafka access...${NC}"
    if nc -z localhost 30092 2>/dev/null; then
        echo -e "${GREEN}Kafka external access is available on port 30092${NC}"
    else
        echo -e "${YELLOW}Kafka external port not yet ready...${NC}"
    fi

    # Deploy Schema Registry
     echo -e "\n${YELLOW}>>> Deploying Schema Registry...${NC}"
     kubectl apply -f manifests/schema-registry.yaml

    # Wait for Schema Registry
     echo -e "${YELLOW}Waiting for Schema Registry to be ready...${NC}"
    if ! kubectl wait --for=condition=available deployment/schema-registry -n messaging --timeout=900s; then
        echo -e "${RED}Schema Registry deployment timeout. Checking logs...${NC}"
        kubectl logs deployment/schema-registry -n messaging
        echo -e "${YELLOW}Continuing with deployment...${NC}"
    else
        echo -e "${GREEN}Schema Registry deployed successfully!${NC}"
    fi

    # Test Schema Registry accessibility
    echo -e "${YELLOW}Testing Schema Registry accessibility...${NC}"
    sleep 10
    if curl -f -s http://localhost:30081/subjects >/dev/null 2>&1; then
        echo -e "${GREEN}Schema Registry is accessible on port 30081${NC}"
    else
        echo -e "${YELLOW}Schema Registry may still be starting up...${NC}"
    fi

    # Deploy Kafka UI
    echo -e "\n${YELLOW}>>> Deploying Kafka UI...${NC}"
    kubectl apply -f manifests/kafka-ui.yaml

    # Wait for Kafka UI
    echo -e "${YELLOW}Waiting for Kafka UI to be ready...${NC}"
    if ! kubectl wait --for=condition=available deployment/kafka-ui -n messaging --timeout=300s; then
        echo -e "${YELLOW}Kafka UI taking longer than expected, but continuing...${NC}"
        kubectl logs deployment/kafka-ui -n messaging --tail=20 | head -10
    else
        echo -e "${GREEN}Kafka UI deployed successfully!${NC}"
    fi

    echo -e "${GREEN}Kafka setup completed!${NC}"
    echo -e "${YELLOW}Access Kafka UI at: http://kafka-ui.local (after configuring Ingress and /etc/hosts)${NC}"
    echo -e "${YELLOW}Schema Registry: http://localhost:30081${NC}"
    echo -e "${YELLOW}Kafka: localhost:30092${NC}"
fi

if [ "$install_keycloak" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Keycloak...${NC}"
    helm install keycloak bitnami/keycloak --namespace security --create-namespace \
        -f values/keycloak.yaml --wait --timeout 300s

    # Get Keycloak admin password
    KEYCLOAK_PASSWORD=$(kubectl get secret --namespace security keycloak -o jsonpath="{.data.admin-password}" | base64 --decode ; echo)
    echo -e "${GREEN}Keycloak deployed successfully!${NC}"
    echo -e "${YELLOW}Keycloak admin password: ${KEYCLOAK_PASSWORD}${NC}"
    echo "$KEYCLOAK_PASSWORD" > keycloak_password.txt
    chmod 600 keycloak_password.txt
    echo -e "${GREEN}Keycloak password saved to keycloak_password.txt${NC}"
fi

if [ "$install_vault" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Vault...${NC}"
    helm install vault hashicorp/vault --namespace vault --create-namespace \
        -f values/vault.yaml --wait --timeout 120s
    echo -e "${GREEN}Vault deployed successfully!${NC}"
fi

if [ "$install_prometheus" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Prometheus...${NC}"
    helm install prometheus prometheus-community/prometheus --namespace monitoring --create-namespace \
        -f values/prometheus.yaml --wait --timeout 120s

    echo -e "\n${YELLOW}>>> Deploying AlertManager...${NC}"
    helm install alertmanager prometheus-community/alertmanager --namespace monitoring \
        -f values/alertmanager.yaml --wait --timeout 120s
    echo -e "${GREEN}Prometheus and AlertManager deployed successfully!${NC}"
fi

if [ "$install_grafana" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Grafana...${NC}"
    helm install grafana grafana/grafana --namespace monitoring --create-namespace \
        -f values/grafana.yaml

    # Wait only for the secret to be created
    echo -e "${YELLOW}Waiting for Grafana secret...${NC}"
    timeout=60
    counter=0
    while [ $counter -lt $timeout ]; do
        if kubectl get secret --namespace monitoring grafana >/dev/null 2>&1; then
            GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
            echo -e "${GREEN}Grafana deployed successfully!${NC}"
            echo -e "${YELLOW}Grafana admin password: ${GRAFANA_PASSWORD}${NC}"
            echo "$GRAFANA_PASSWORD" > grafana_password.txt
            chmod 600 grafana_password.txt
            echo -e "${GREEN}Grafana password saved to grafana_password.txt${NC}"
            break
        fi
        echo -e "${YELLOW}Waiting for Grafana secret... ($counter/$timeout seconds)${NC}"
        sleep 5
        counter=$((counter + 5))
    done

    if [ $counter -ge $timeout ]; then
        echo -e "${YELLOW}Grafana still deploying, password will be available shortly${NC}"
    fi
fi

if [ "$install_ingress" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Nginx Ingress Controller...${NC}"

    # Check if monitoring CRDs are available
    ingress_monitoring_enabled="false"
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        ingress_monitoring_enabled="true"
        echo -e "${YELLOW}ServiceMonitor CRD detected, enabling Ingress monitoring...${NC}"
    else
        echo -e "${YELLOW}No ServiceMonitor CRD detected, deploying Ingress without monitoring...${NC}"
    fi

    # Deploy with retries and longer timeout per attempt
    max_attempts=2
    attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo -e "${YELLOW}Deployment attempt $attempt/$max_attempts...${NC}"

        if helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace \
            --set controller.metrics.enabled="$ingress_monitoring_enabled" \
            --set controller.metrics.serviceMonitor.enabled="$ingress_monitoring_enabled" \
            --set controller.admissionWebhooks.enabled=false \
            --set controller.hostPort.enabled=false \
            --set controller.service.type=NodePort \
            --set controller.service.nodePorts.http=30080 \
            --set controller.service.nodePorts.https=30443 \
            --set controller.resources.requests.cpu=50m \
            --set controller.resources.requests.memory=64Mi \
            --set controller.resources.limits.cpu=200m \
            --set controller.resources.limits.memory=256Mi \
            -f values/ingress-nginx.yaml --wait --timeout 180s; then

            echo -e "${GREEN}Nginx Ingress Controller deployed successfully!${NC}"
            break

        else
            echo -e "${YELLOW}Attempt $attempt failed...${NC}"

            if [ $attempt -eq $max_attempts ]; then
                echo -e "${RED}All deployment attempts failed. Skipping Ingress installation.${NC}"
                echo -e "${YELLOW}You can try manually later with:${NC}"
                echo -e "${YELLOW}  helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.admissionWebhooks.enabled=false${NC}"
                break
            else
                echo -e "${YELLOW}Cleaning up and retrying in 15 seconds...${NC}"
                helm uninstall ingress-nginx --namespace ingress-nginx 2>/dev/null || true
                sleep 15
                attempt=$((attempt + 1))
            fi
        fi
    done
fi

if [ "$install_minio" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying MinIO...${NC}"

    # Generate random password for MinIO if not already created
    if [ ! -f minio_password.txt ]; then
        MINIO_PASSWORD=$(openssl rand -base64 12)
        echo "$MINIO_PASSWORD" > minio_password.txt
        chmod 600 minio_password.txt
    else
        MINIO_PASSWORD=$(cat minio_password.txt)
    fi

    # Check if Prometheus CRDs are installed to enable monitoring
    monitoring_enabled="false"
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        monitoring_enabled="true"
        echo -e "${YELLOW}ServiceMonitor CRD detected, enabling MinIO monitoring...${NC}"
    else
        echo -e "${YELLOW}No ServiceMonitor CRD detected, deploying MinIO without monitoring...${NC}"
    fi

    helm install minio minio/minio --namespace storage --create-namespace \
        --set rootUser=admin \
        --set rootPassword="$MINIO_PASSWORD" \
        --set metrics.serviceMonitor.enabled="$monitoring_enabled" \
        --set prometheusRule.enabled="$monitoring_enabled" \
        --set serviceAccount.create=true \
        --set serviceAccount.name=minio \
        -f values/minio.yaml --wait --timeout 90s

    echo -e "${GREEN}MinIO deployed successfully!${NC}"
    echo -e "${YELLOW}MinIO credentials saved to minio_password.txt${NC}"
fi

if [ "$install_elasticsearch" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Elasticsearch (background)...${NC}"
    # Démarrage sans attente
    helm install elasticsearch elastic/elasticsearch --namespace logging --create-namespace \
        -f values/elasticsearch.yaml

    echo -e "${YELLOW}>>> Deploying Kibana (will wait for Elasticsearch)...${NC}"
    helm install kibana elastic/kibana --namespace logging \
        -f values/kibana.yaml

    # Fonction d'attente en arrière-plan
    (
        echo -e "${YELLOW}Waiting for Elasticsearch to be ready in background...${NC}"
        kubectl wait --for=condition=Ready pods -l app=elasticsearch-master -n logging --timeout=600s
        echo -e "${GREEN}Elasticsearch is now ready!${NC}"
    ) &

    echo -e "${GREEN}Elasticsearch and Kibana deployment started!${NC}"

    # Create elastic admin user if not exists
    if ! kubectl get secret -n logging elastic-credentials &> /dev/null; then
        # Generate a random password
        ELASTIC_PASSWORD=$(openssl rand -base64 12)
        kubectl create secret generic elastic-credentials \
            --namespace logging \
            --from-literal=username=elastic \
            --from-literal=password="$ELASTIC_PASSWORD"

        echo "$ELASTIC_PASSWORD" > elasticsearch_password.txt
        chmod 600 elasticsearch_password.txt
        echo -e "${GREEN}Elasticsearch password saved to elasticsearch_password.txt${NC}"
    fi
fi

if [ "$install_dashboard" = true ]; then
    echo -e "\n${YELLOW}>>> Deploying Kubernetes Dashboard...${NC}"
    helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
        --namespace kubernetes-dashboard --create-namespace \
        -f values/dashboard.yaml --wait --timeout 900s

    # Wait for dashboard pods to be ready
    echo -e "${YELLOW}Waiting for dashboard pods to be ready...${NC}"
    kubectl wait --for=condition=Ready pods --all -n kubernetes-dashboard --timeout=300s || true

    # Create admin user for Dashboard
    echo -e "${YELLOW}>>> Configuring Dashboard access (admin ServiceAccount)...${NC}"
    kubectl create serviceaccount admin-user -n kubernetes-dashboard

    # Create ClusterRoleBinding
    kubectl create clusterrolebinding admin-user-binding --clusterrole=cluster-admin \
        --serviceaccount=kubernetes-dashboard:admin-user

    # Create permanent token via the external YAML file
    echo -e "${YELLOW}Creating permanent token for dashboard access...${NC}"
    kubectl apply -f manifests/admin-token-secret.yaml

    # Wait for the secret to be properly populated with token
    echo -e "${YELLOW}Waiting for token secret to be populated...${NC}"
    sleep 5

    # Retrieve the permanent token
    DASH_TOKEN=$(kubectl -n kubernetes-dashboard get secret admin-user-token -o jsonpath='{.data.token}' | base64 --decode)

    # Check if token was successfully retrieved
    if [ -z "$DASH_TOKEN" ]; then
        echo -e "${YELLOW}Token not found yet, waiting longer...${NC}"
        sleep 10
        DASH_TOKEN=$(kubectl -n kubernetes-dashboard get secret admin-user-token -o jsonpath='{.data.token}' | base64 --decode)

        # If still empty, fall back to the temporary token
        if [ -z "$DASH_TOKEN" ]; then
            echo -e "${YELLOW}Permanent token not available, using temporary token instead...${NC}"
            DASH_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user --duration=24h)
        fi
    fi

    # Save token to file for future reference with restrictive permissions
    echo "$DASH_TOKEN" > dashboard_token.txt
    chmod 600 dashboard_token.txt
    echo -e "${GREEN}Token saved to dashboard_token.txt${NC}"

    # Copy token to clipboard
    copy_token_to_clipboard "$DASH_TOKEN"

    # Print available dashboard services
    echo -e "${YELLOW}Available dashboard services:${NC}"
    kubectl get svc -n kubernetes-dashboard

    if confirm "Start port-forward for dashboard now? (Recommended for immediate access)" "Y"; then
        # Try up to 3 times with increasing sleep time between attempts
        for attempt in {1..3}; do
            echo -e "${YELLOW}Port-forward attempt $attempt/3...${NC}"
            if start_port_forward; then
                # Success
                break
            else
                echo -e "${YELLOW}Port-forward attempt $attempt failed. Waiting before retry...${NC}"
                sleep $((attempt * 5))

                if [ "$attempt" -eq 3 ]; then
                    echo -e "${RED}All port-forward attempts failed.${NC}"
                    echo -e "${YELLOW}You can try manually later with:${NC}"
                    echo -e "${YELLOW}kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443${NC}"
                fi
            fi
        done

        # If port-forward started successfully, offer to open browser
        if [ -f dashboard_portforward.pid ] && [ -s dashboard_portforward.pid ]; then
            if confirm "Open dashboard in browser?" "Y"; then
                open_dashboard
            fi
        fi
    fi

    echo -e "${GREEN}===================================================================${NC}"
    echo -e "${GREEN} Kubernetes Dashboard is deployed!${NC}"
    echo -e "${GREEN} Access URLs:${NC}"
    echo -e "${GREEN} - Port-forward URL (recommended): https://localhost:8443${NC}"
    echo -e "${GREEN} Authentication token (admin-user):${NC}"
    echo -e "${YELLOW}$DASH_TOKEN${NC}"
    echo -e "${GREEN} Manual port-forward command:${NC}"
    echo -e "${YELLOW} kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443${NC}"
    echo -e "${GREEN}===================================================================${NC}"
fi

### Show service access details ###
if [ "$install_prometheus" = true ] || [ "$install_grafana" = true ]; then
    echo -e "\n${GREEN}=== Monitoring Service Access ===${NC}"

    if [ "$install_prometheus" = true ]; then
        echo -e "${YELLOW}Access Prometheus${NC}"
        echo -e "${YELLOW}Run: kubectl port-forward svc/prometheus-server 9090:80 -n monitoring${NC}"
        echo -e "${YELLOW}Then open: http://localhost:9090${NC}"
    fi

    if [ "$install_grafana" = true ]; then
        echo -e "${YELLOW}Access Grafana${NC}"
        echo -e "${YELLOW}Run: kubectl port-forward svc/grafana 3000:80 -n monitoring${NC}"
        echo -e "${YELLOW}Then open: http://localhost:3000${NC}"
        echo -e "${YELLOW}Username: admin, Password: $(cat grafana_password.txt)${NC}"
    fi
fi

if [ "$install_elasticsearch" = true ]; then
    echo -e "\n${GREEN}=== Logging Service Access ===${NC}"
    echo -e "${YELLOW}Access Kibana${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/kibana-kibana 5601:5601 -n logging${NC}"
    echo -e "${YELLOW}Then open: http://localhost:5601${NC}"
    if [ -f elasticsearch_password.txt ]; then
        echo -e "${YELLOW}Username: elastic, Password: $(cat elasticsearch_password.txt)${NC}"
    fi
fi

if [ "$install_kafka" = true ]; then
    echo -e "\n${GREEN}=== Messaging Service Access ===${NC}"
    echo -e "${YELLOW}Access Kafka${NC}"
    echo -e "${YELLOW}Inside the cluster: kafka.messaging.svc.cluster.local:9092${NC}"
    echo -e "${YELLOW}For external access, execute ./deploy-ingress.sh or use port forwarding${NC}"
    echo -e "${YELLOW}Example port-forward: kubectl port-forward svc/kafka 9092:9092 -n messaging${NC}"
fi

if [ "$install_postgres" = true ]; then
    echo -e "\n${GREEN}=== Database Service Access ===${NC}"
    echo -e "${YELLOW}Access PostgreSQL${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/postgresql 5432:5432 -n database${NC}"
    echo -e "${YELLOW}Connection: postgresql://myapp:$(cat postgres_password.txt)@localhost:5432/myapp${NC}"
    echo -e "${YELLOW}Admin connection: postgresql://postgres:$(cat postgres_password.txt)@localhost:5432/postgres${NC}"
fi

if [ "$install_redis" = true ]; then
    echo -e "\n${GREEN}=== Cache Service Access ===${NC}"
    echo -e "${YELLOW}Access Redis${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/redis-master 6379:6379 -n cache${NC}"
    echo -e "${YELLOW}Connection: redis://localhost:6379 (password: $(cat redis_password.txt))${NC}"
    echo -e "${YELLOW}Redis CLI: kubectl exec -it svc/redis-master -n cache -- redis-cli -a $(cat redis_password.txt)${NC}"
fi

if [ "$install_keycloak" = true ]; then
    echo -e "\n${GREEN}=== Security Service Access ===${NC}"
    echo -e "${YELLOW}Access Keycloak${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/keycloak 8080:80 -n security${NC}"
    echo -e "${YELLOW}Then open: http://localhost:8080${NC}"
    echo -e "${YELLOW}Username: admin, Password: $(cat keycloak_password.txt)${NC}"
fi

if [ "$install_minio" = true ]; then
    echo -e "\n${GREEN}=== MinIO Service Access ===${NC}"
    echo -e "${YELLOW}Access MinIO Console${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/minio-console 9001:9001 -n storage${NC}"
    echo -e "${YELLOW}Then open: http://localhost:9001${NC}"
    echo -e "${YELLOW}Username: admin, Password: $(cat minio_password.txt)${NC}"
    echo -e "${YELLOW}S3 API Endpoint: minio.storage.svc.cluster.local:9000${NC}"
fi

if [ "$install_vault" = true ]; then
    echo -e "\n${GREEN}=== Vault Service Access ===${NC}"
    echo -e "${YELLOW}Access Vault${NC}"
    echo -e "${YELLOW}Run: kubectl port-forward svc/vault 8200:8200 -n vault${NC}"
    echo -e "${YELLOW}Then open: http://localhost:8200${NC}"
    echo -e "${YELLOW}Get the root token: kubectl get secrets -n vault vault-keys -o jsonpath='{.data.vault-root}' | base64 -d${NC}"
fi

# Summary of installation
echo -e "\n${BLUE}Installation Summary:${NC}"

# K3s cluster status
if [ "$create_new_cluster" = true ]; then
    echo -e "  - K3s cluster: ${GREEN}Created/Recreated${NC}"
else
    echo -e "  - K3s cluster: ${GREEN}Existing (kept)${NC}"
fi

# Dashboard
if [ "${dashboard_installed:-false}" = true ]; then
    echo -e "  - Kubernetes Dashboard: ${GREEN}Already installed${NC}"
elif [ "$install_dashboard" = true ]; then
    echo -e "  - Kubernetes Dashboard: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Kubernetes Dashboard: ${YELLOW}Not installed${NC}"
fi

# PostgreSQL
if [ "${postgres_installed:-false}" = true ]; then
    echo -e "  - PostgreSQL: ${GREEN}Already installed${NC}"
elif [ "$install_postgres" = true ]; then
    echo -e "  - PostgreSQL: ${GREEN}Newly installed${NC}"
else
    echo -e "  - PostgreSQL: ${YELLOW}Not installed${NC}"
fi

# Redis
if [ "${redis_installed:-false}" = true ]; then
    echo -e "  - Redis: ${GREEN}Already installed${NC}"
elif [ "$install_redis" = true ]; then
    echo -e "  - Redis: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Redis: ${YELLOW}Not installed${NC}"
fi

# Kafka
if [ "${kafka_installed:-false}" = true ]; then
    echo -e "  - Kafka: ${GREEN}Already installed${NC}"
elif [ "$install_kafka" = true ]; then
    echo -e "  - Kafka: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Kafka: ${YELLOW}Not installed${NC}"
fi

# Vault
if [ "${vault_installed:-false}" = true ]; then
    echo -e "  - Vault: ${GREEN}Already installed${NC}"
elif [ "$install_vault" = true ]; then
    echo -e "  - Vault: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Vault: ${YELLOW}Not installed${NC}"
fi

# Prometheus
if [ "${prometheus_installed:-false}" = true ]; then
    echo -e "  - Prometheus: ${GREEN}Already installed${NC}"
elif [ "$install_prometheus" = true ]; then
    echo -e "  - Prometheus: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Prometheus: ${YELLOW}Not installed${NC}"
fi

# Grafana
if [ "${grafana_installed:-false}" = true ]; then
    echo -e "  - Grafana: ${GREEN}Already installed${NC}"
elif [ "$install_grafana" = true ]; then
    echo -e "  - Grafana: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Grafana: ${YELLOW}Not installed${NC}"
fi

# Elasticsearch/Kibana
if [ "${elasticsearch_installed:-false}" = true ]; then
    echo -e "  - Elasticsearch/Kibana: ${GREEN}Already installed${NC}"
elif [ "$install_elasticsearch" = true ]; then
    echo -e "  - Elasticsearch/Kibana: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Elasticsearch/Kibana: ${YELLOW}Not installed${NC}"
fi

# Keycloak
if [ "${keycloak_installed:-false}" = true ]; then
    echo -e "  - Keycloak: ${GREEN}Already installed${NC}"
elif [ "$install_keycloak" = true ]; then
    echo -e "  - Keycloak: ${GREEN}Newly installed${NC}"
else
    echo -e "  - Keycloak: ${YELLOW}Not installed${NC}"
fi

# Ingress
if [ "${ingress_installed:-false}" = true ]; then
    echo -e "  - Ingress (Nginx): ${GREEN}Already installed${NC}"
elif [ "$install_ingress" = true ]; then
    echo -e "  - Ingress (Nginx): ${GREEN}Newly installed${NC}"
else
    echo -e "  - Ingress: ${YELLOW}Not installed${NC}"
fi

# MinIO
if [ "${minio_installed:-false}" = true ]; then
    echo -e "  - MinIO: ${GREEN}Already installed${NC}"
elif [ "$install_minio" = true ]; then
    echo -e "  - MinIO: ${GREEN}Newly installed${NC}"
else
    echo -e "  - MinIO: ${YELLOW}Not installed${NC}"
fi

echo -e "\n${YELLOW}Use 'kubectl get pods -A' to verify all pods are in RUNNING state.${NC}"
echo -e "${GREEN}Setup completed successfully!${NC}"