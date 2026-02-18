#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s VPS Installation Script
# Installs a minimal K3s cluster optimized for 4-6GB RAM VPS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3D_STACK_ROOT="$(dirname "$SCRIPT_DIR")"

# Set KUBECONFIG for k3s (required for Helm and kubectl)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Configuration
K3S_VERSION="${K3S_VERSION:-v1.29.0+k3s1}"
INSTALL_PROMETHEUS="${INSTALL_PROMETHEUS:-true}"
INSTALL_GRAFANA="${INSTALL_GRAFANA:-true}"
INSTALL_KEYCLOAK="${INSTALL_KEYCLOAK:-true}"
INSTALL_POSTGRESQL="${INSTALL_POSTGRESQL:-true}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
INSTALL_SEALED_SECRETS="${INSTALL_SEALED_SECRETS:-true}"
INSTALL_REDIS="${INSTALL_REDIS:-true}"
INSTALL_NETWORK_POLICIES="${INSTALL_NETWORK_POLICIES:-true}"
ENABLE_AUDIT_LOGGING="${ENABLE_AUDIT_LOGGING:-true}"

# Gateway API (successor to Ingress)
# Uses NGINX Gateway Fabric as the controller implementation
INSTALL_GATEWAY_API="${INSTALL_GATEWAY_API:-true}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}         K3s VPS Installation - Minimal Stack                  ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

check_system() {
    echo -e "\n${YELLOW}>>> Checking system requirements...${NC}"
    
    # Check OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo -e "${GREEN}✓ OS: $NAME $VERSION${NC}"
    fi
    
    # Check RAM
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    echo -e "${GREEN}✓ RAM: ${total_ram}MB${NC}"
    
    if [[ $total_ram -lt 3500 ]]; then
        echo -e "${RED}Warning: Less than 4GB RAM detected. Some services may not start.${NC}"
    fi
    
    # Check disk space
    disk_free=$(df -h / | awk 'NR==2 {print $4}')
    echo -e "${GREEN}✓ Disk free: $disk_free${NC}"
}

# -----------------------------------------------------------------------------
# Install dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    echo -e "\n${YELLOW}>>> Installing dependencies...${NC}"
    
    apt-get update -qq
    apt-get install -y -qq curl wget git jq openssl apt-transport-https ca-certificates
    
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

# -----------------------------------------------------------------------------
# Setup audit logging
# -----------------------------------------------------------------------------
setup_audit_logging() {
    if [[ "$ENABLE_AUDIT_LOGGING" != "true" ]]; then
        return 0
    fi
    
    echo -e "${YELLOW}>>> Configuring audit logging...${NC}"
    
    # Create audit config directory
    mkdir -p /var/lib/rancher/k3s/server/audit
    
    # Copy audit policy
    if [[ -f "$SCRIPT_DIR/manifests/audit-policy.yaml" ]]; then
        cp "$SCRIPT_DIR/manifests/audit-policy.yaml" /var/lib/rancher/k3s/server/audit/policy.yaml
        echo -e "${GREEN}✓ Audit policy installed${NC}"
    else
        echo -e "${YELLOW}⚠ audit-policy.yaml not found, using default policy${NC}"
        cat > /var/lib/rancher/k3s/server/audit/policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: Metadata
EOF
    fi
}

# -----------------------------------------------------------------------------
# Install K3s
# -----------------------------------------------------------------------------
install_k3s() {
    echo -e "\n${YELLOW}>>> Installing K3s ${K3S_VERSION}...${NC}"
    
    if command -v k3s &> /dev/null; then
        echo -e "${GREEN}✓ K3s already installed${NC}"
        return 0
    fi
    
    # Setup audit logging before K3s installation
    setup_audit_logging
    
    # Build K3s install arguments
    # Note: metrics-server is ENABLED for HPA (Horizontal Pod Autoscaler) support
    local k3s_args="--disable traefik --disable servicelb"
    k3s_args="$k3s_args --write-kubeconfig-mode 600"
    k3s_args="$k3s_args --kube-apiserver-arg=enable-admission-plugins=NodeRestriction"
    k3s_args="$k3s_args --kubelet-arg=max-pods=100"
    
    # Add audit logging arguments if enabled
    if [[ "$ENABLE_AUDIT_LOGGING" == "true" ]]; then
        k3s_args="$k3s_args --kube-apiserver-arg=audit-policy-file=/var/lib/rancher/k3s/server/audit/policy.yaml"
        k3s_args="$k3s_args --kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit/audit.log"
        k3s_args="$k3s_args --kube-apiserver-arg=audit-log-maxage=7"
        k3s_args="$k3s_args --kube-apiserver-arg=audit-log-maxbackup=3"
        k3s_args="$k3s_args --kube-apiserver-arg=audit-log-maxsize=50"
        mkdir -p /var/log/kubernetes/audit
    fi
    
    # Install K3s with minimal footprint
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - $k3s_args
    
    # Wait for K3s to be ready
    echo -e "${YELLOW}Waiting for K3s to be ready...${NC}"
    sleep 10
    
    until kubectl get nodes &> /dev/null; do
        echo "Waiting for K3s API..."
        sleep 5
    done
    
    kubectl wait --for=condition=Ready node --all --timeout=120s
    
    echo -e "${GREEN}✓ K3s installed and running${NC}"
}

# -----------------------------------------------------------------------------
# Install Helm
# -----------------------------------------------------------------------------
install_helm() {
    echo -e "\n${YELLOW}>>> Installing Helm...${NC}"
    
    if command -v helm &> /dev/null; then
        echo -e "${GREEN}✓ Helm already installed${NC}"
        return 0
    fi
    
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    echo -e "${GREEN}✓ Helm installed${NC}"
}

# -----------------------------------------------------------------------------
# Setup Helm repositories
# -----------------------------------------------------------------------------
setup_helm_repos() {
    echo -e "\n${YELLOW}>>> Setting up Helm repositories...${NC}"
    
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
    
    # Note: NGINX Gateway Fabric uses OCI registry (oci://ghcr.io/nginx/charts/nginx-gateway-fabric)
    # No need to add a traditional Helm repo for it
    
    helm repo update
    
    echo -e "${GREEN}✓ Helm repositories configured${NC}"
}

# -----------------------------------------------------------------------------
# Create namespaces
# -----------------------------------------------------------------------------
create_namespaces() {
    echo -e "\n${YELLOW}>>> Creating namespaces...${NC}"
    
    kubectl apply -f "$SCRIPT_DIR/namespaces/"
    
    echo -e "${GREEN}✓ Namespaces created${NC}"
}

# -----------------------------------------------------------------------------
# Install Gateway API (using NGINX Gateway Fabric)
# Uses NGINX Gateway Fabric as the controller implementation
# -----------------------------------------------------------------------------
install_gateway_api() {
    if [[ "$INSTALL_GATEWAY_API" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Gateway API (INSTALL_GATEWAY_API=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Gateway API...${NC}"
    
    # Step 1: Install Gateway API CRDs (Standard channel)
    echo -e "${YELLOW}Installing Gateway API CRDs (${GATEWAY_API_VERSION})...${NC}"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    
    # Wait for CRDs to be established
    echo -e "${YELLOW}Waiting for Gateway API CRDs to be established...${NC}"
    kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s
    kubectl wait --for=condition=Established crd/referencegrants.gateway.networking.k8s.io --timeout=60s
    
    echo -e "${GREEN}✓ Gateway API CRDs installed${NC}"
    
    # Step 2: Create nginx-gateway namespace (if not already created via namespaces/)
    kubectl create namespace nginx-gateway --dry-run=client -o yaml | kubectl apply -f -
    
    # Step 3: Install NGINX Gateway Fabric (from OCI registry)
    echo -e "${YELLOW}Installing NGINX Gateway Fabric...${NC}"
    helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
        --namespace nginx-gateway \
        -f "$SCRIPT_DIR/values/nginx-gateway-fabric.yaml" \
        --wait --timeout 5m
    
    # Step 4: Create GatewayClass
    echo -e "${YELLOW}Creating GatewayClass...${NC}"
    kubectl apply -f "$SCRIPT_DIR/manifests/gatewayclass.yaml"
    
    # Wait for NGINX Gateway Fabric to be ready
    echo -e "${YELLOW}Waiting for NGINX Gateway Fabric to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nginx-gateway-fabric \
        -n nginx-gateway --timeout=300s || true
    
    echo -e "${GREEN}✓ Gateway API installed (NGINX Gateway Fabric)${NC}"
    echo -e "${YELLOW}  Next: Create a Gateway resource with setup-gateway-api.sh${NC}"
}

# -----------------------------------------------------------------------------
# Install PostgreSQL
# -----------------------------------------------------------------------------
install_postgresql() {
    if [[ "$INSTALL_POSTGRESQL" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping PostgreSQL (INSTALL_POSTGRESQL=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing PostgreSQL...${NC}"
    
    kubectl create namespace storage --dry-run=client -o yaml | kubectl apply -f -
    
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace storage \
        -f "$SCRIPT_DIR/values/postgresql.yaml" \
        --wait --timeout 5m
    
    echo -e "${GREEN}✓ PostgreSQL installed${NC}"
}

# -----------------------------------------------------------------------------
# Create Keycloak database in PostgreSQL
# Must be called AFTER PostgreSQL is installed and running
# -----------------------------------------------------------------------------
create_keycloak_database() {
    if [[ "$INSTALL_KEYCLOAK" != "true" || "$INSTALL_POSTGRESQL" != "true" ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Creating Keycloak database in PostgreSQL...${NC}"
    
    # Wait for PostgreSQL to be ready
    echo -e "${YELLOW}Waiting for PostgreSQL to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=120s
    
    # Get passwords from secrets
    local pg_admin_pass
    pg_admin_pass=$(kubectl get secret -n storage postgresql-secret -o jsonpath="{.data.postgres-password}" | base64 -d)
    
    local kc_db_pass
    kc_db_pass=$(kubectl get secret -n security keycloak-db-secret -o jsonpath="{.data.password}" | base64 -d)
    
    # Create keycloak user and database using -i flag for proper stdin handling
    kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="${pg_admin_pass}" psql -U postgres <<EOSQL 2>/dev/null
-- Create keycloak user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
        CREATE USER keycloak WITH PASSWORD '${kc_db_pass}';
    ELSE
        ALTER USER keycloak WITH PASSWORD '${kc_db_pass}';
    END IF;
END
\$\$;

-- Create keycloak database if not exists
SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
    
    echo -e "${GREEN}✓ Keycloak database created${NC}"
}

# -----------------------------------------------------------------------------
# Install Keycloak (using official image from quay.io)
# -----------------------------------------------------------------------------
install_keycloak() {
    if [[ "$INSTALL_KEYCLOAK" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Keycloak (INSTALL_KEYCLOAK=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Keycloak (official image)...${NC}"
    
    kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
    
    # Use official Keycloak manifest (not Bitnami chart due to image restrictions)
    kubectl apply -f "$SCRIPT_DIR/manifests/keycloak.yaml"
    
    # Wait for Keycloak to be ready (can take a few minutes)
    echo -e "${YELLOW}Waiting for Keycloak to start (this may take 2-5 minutes)...${NC}"
    kubectl wait --for=condition=ready pod -l app=keycloak \
        -n security --timeout=600s || true
    
    echo -e "${GREEN}✓ Keycloak installed${NC}"
}

# -----------------------------------------------------------------------------
# Install Redis (for rate limiting & caching)
# -----------------------------------------------------------------------------
install_redis() {
    if [[ "$INSTALL_REDIS" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Redis (INSTALL_REDIS=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Redis...${NC}"
    
    # Create database namespace if not exists
    kubectl apply -f "$SCRIPT_DIR/namespaces/database.yaml"
    
    # Deploy Redis
    kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"
    
    # Wait for Redis to be ready
    echo -e "${YELLOW}Waiting for Redis to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app=redis \
        -n database --timeout=120s || true
    
    echo -e "${GREEN}✓ Redis installed (redis.database.svc.cluster.local:6379)${NC}"
}

# -----------------------------------------------------------------------------
# Install Prometheus
# -----------------------------------------------------------------------------
install_prometheus() {
    if [[ "$INSTALL_PROMETHEUS" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Prometheus (INSTALL_PROMETHEUS=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Prometheus...${NC}"
    
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    helm upgrade --install prometheus prometheus-community/prometheus \
        --namespace monitoring \
        -f "$SCRIPT_DIR/values/prometheus.yaml" \
        --wait --timeout 5m
    
    echo -e "${GREEN}✓ Prometheus installed${NC}"
}

# -----------------------------------------------------------------------------
# Install Grafana
# -----------------------------------------------------------------------------
install_grafana() {
    if [[ "$INSTALL_GRAFANA" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Grafana (INSTALL_GRAFANA=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Grafana...${NC}"
    
    helm upgrade --install grafana grafana/grafana \
        --namespace monitoring \
        -f "$SCRIPT_DIR/values/grafana.yaml" \
        --wait --timeout 5m
    
    echo -e "${GREEN}✓ Grafana installed${NC}"
}

# -----------------------------------------------------------------------------
# Install Sealed Secrets
# -----------------------------------------------------------------------------
install_sealed_secrets() {
    if [[ "$INSTALL_SEALED_SECRETS" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Sealed Secrets (INSTALL_SEALED_SECRETS=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Sealed Secrets Controller...${NC}"
    
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace kube-system \
        -f "$SCRIPT_DIR/values/sealed-secrets.yaml" \
        --wait --timeout 3m
    
    # Wait for controller to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets \
        -n kube-system --timeout=120s || true
    
    echo -e "${GREEN}✓ Sealed Secrets Controller installed${NC}"
    
    # SECURITY: Store in /root/ - use export-secrets.sh to retrieve
    local secrets_dir="/root/.k3s-secrets"
    mkdir -p "$secrets_dir"
    
    # Export public key for client-side encryption
    echo -e "${YELLOW}>>> Exporting Sealed Secrets public key...${NC}"
    
    # Wait a moment for the controller to generate its key
    sleep 5
    
    # Extract cert directly from the controller's secret (no kubeseal needed)
    local secret_name
    secret_name=$(kubectl get secrets -n kube-system -o name 2>/dev/null | grep sealed-secrets-key | head -1 | cut -d'/' -f2)
    
    if [[ -n "$secret_name" ]]; then
        kubectl get secret -n kube-system "$secret_name" -o jsonpath='{.data.tls\.crt}' | \
            base64 -d > "$secrets_dir/sealed-secrets-pub.pem" 2>/dev/null
    fi
    
    if [[ -s "$secrets_dir/sealed-secrets-pub.pem" ]]; then
        echo -e "${GREEN}✓ Public key saved to /root/.k3s-secrets/sealed-secrets-pub.pem${NC}"
        echo -e "${YELLOW}  Export with: sudo ./vps/scripts/export-secrets.sh export-cert /tmp/cert.pem${NC}"
    else
        echo -e "${YELLOW}⚠ Could not export public key (controller may still be initializing)${NC}"
        echo -e "${YELLOW}  Run later: sudo ./vps/scripts/export-secrets.sh export-cert /tmp/cert.pem${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Install Argo CD
# -----------------------------------------------------------------------------
install_argocd() {
    if [[ "$INSTALL_ARGOCD" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Argo CD (INSTALL_ARGOCD=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Argo CD...${NC}"
    
    # Create namespace
    kubectl apply -f "$SCRIPT_DIR/namespaces/gitops.yaml"
    
    # Install Argo CD
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        -f "$SCRIPT_DIR/values/argocd.yaml" \
        --wait --timeout 5m
    
    # Wait for Argo CD server to be ready
    echo -e "${YELLOW}Waiting for Argo CD to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
        -n argocd --timeout=300s || true
    
    echo -e "${GREEN}✓ Argo CD installed${NC}"
}

# -----------------------------------------------------------------------------
# Install Argo CD Image Updater
# -----------------------------------------------------------------------------
install_argocd_image_updater() {
    if [[ "$INSTALL_ARGOCD" != "true" ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing Argo CD Image Updater...${NC}"
    
    helm upgrade --install argocd-image-updater argo/argocd-image-updater \
        --namespace argocd \
        -f "$SCRIPT_DIR/values/argocd-image-updater.yaml" \
        --wait --timeout 3m
    
    echo -e "${GREEN}✓ Argo CD Image Updater installed${NC}"
}

# -----------------------------------------------------------------------------
# Generate manifests from templates
# -----------------------------------------------------------------------------
generate_manifests() {
    echo -e "\n${YELLOW}>>> Generating manifests from templates...${NC}"
    
    if [[ -f "$SCRIPT_DIR/scripts/apply-config.sh" ]]; then
        if [[ -f "$SCRIPT_DIR/config.env" ]]; then
            bash "$SCRIPT_DIR/scripts/apply-config.sh"
            echo -e "${GREEN}✓ Manifests generated${NC}"
        else
            echo -e "${YELLOW}⚠ config.env not found, using existing manifests${NC}"
            echo -e "  Create from: cp $SCRIPT_DIR/config.env.example $SCRIPT_DIR/config.env"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Setup Argo CD Auto-Discovery
# -----------------------------------------------------------------------------
setup_argocd_autodiscover() {
    if [[ "$INSTALL_ARGOCD" != "true" ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Setting up Argo CD Auto-Discovery...${NC}"
    
    # Apply the autodiscover ApplicationSets (scm-token is managed separately via export-secrets.sh)
    if [[ -f "$SCRIPT_DIR/manifests/argocd-autodiscover.yaml" ]]; then
        kubectl apply -f "$SCRIPT_DIR/manifests/argocd-autodiscover.yaml"
        echo -e "${GREEN}✓ Auto-Discovery ApplicationSets created${NC}"
    else
        echo -e "${YELLOW}⚠ argocd-autodiscover.yaml not found, skipping${NC}"
    fi
    
    # Apply ImageUpdater CRs (required by argocd-image-updater v1.1.0+ to detect Applications)
    if [[ -f "$SCRIPT_DIR/manifests/argocd-image-updater-crs.yaml" ]]; then
        kubectl apply -f "$SCRIPT_DIR/manifests/argocd-image-updater-crs.yaml"
        echo -e "${GREEN}✓ Image Updater CRs created (alpha + prod)${NC}"
    else
        echo -e "${YELLOW}⚠ argocd-image-updater-crs.yaml not found, skipping${NC}"
    fi
    
    echo -e "${YELLOW}⚠ Don't forget to set the SCM token:${NC}"
    echo -e "  ${BLUE}sudo ./vps/scripts/export-secrets.sh set-scm-credentials github${NC}"
}

# -----------------------------------------------------------------------------
# Setup secrets (generates passwords and creates K8s secrets)
# -----------------------------------------------------------------------------
setup_secrets() {
    echo -e "\n${YELLOW}>>> Setting up secrets...${NC}"
    
    if [[ -f "$SCRIPT_DIR/scripts/setup-secrets.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-secrets.sh" setup
    else
        echo -e "${RED}Error: scripts/setup-secrets.sh not found${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Setup PostgreSQL Backup CronJob
# -----------------------------------------------------------------------------
setup_postgres_backup() {
    echo -e "\n${YELLOW}>>> Setting up PostgreSQL backup CronJob...${NC}"
    
    # Check if helm chart directory exists
    if [[ -d "$SCRIPT_DIR/postgres-backup" ]]; then
        helm upgrade --install postgres-backup "$SCRIPT_DIR/postgres-backup" \
            --namespace storage \
            --wait --timeout 2m || true
        echo -e "${GREEN}✓ PostgreSQL backup CronJobs configured (daily/weekly/monthly)${NC}"
    else
        echo -e "${YELLOW}⚠ postgres-backup chart not found, skipping${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Apply Network Policies (security hardening)
# -----------------------------------------------------------------------------
apply_network_policies() {
    if [[ "$INSTALL_NETWORK_POLICIES" != "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Network Policies (INSTALL_NETWORK_POLICIES=false)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Applying Network Policies (security hardening)...${NC}"
    
    if [[ -f "$SCRIPT_DIR/manifests/network-policies.yaml" ]]; then
        kubectl apply -f "$SCRIPT_DIR/manifests/network-policies.yaml"
        echo -e "${GREEN}✓ Network Policies applied${NC}"
        echo -e "${YELLOW}  Pod-to-pod communication is now restricted${NC}"
    else
        echo -e "${YELLOW}⚠ network-policies.yaml not found, skipping${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Print summary
# -----------------------------------------------------------------------------
print_summary() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Installation Complete!                               ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Cluster Info:${NC}"
    kubectl get nodes
    
    echo -e "\n${YELLOW}Services per namespace:${NC}"
    local namespaces="storage database security monitoring nginx-gateway argocd"
    for ns in $namespaces; do
        echo -e "\n${BLUE}[$ns]${NC}"
        kubectl get pods -n $ns 2>/dev/null || echo "  (empty)"
    done
    
    # Get external IP
    EXTERNAL_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo -e "\n${YELLOW}Access Information:${NC}"
    echo -e "  Kubeconfig: /etc/rancher/k3s/k3s.yaml"
    echo -e "  External IP: ${EXTERNAL_IP}"
    echo -e "  Credentials: sudo ./vps/scripts/export-secrets.sh show"
    
    if [[ "$INSTALL_GRAFANA" == "true" ]]; then
        echo -e "\n${YELLOW}Grafana:${NC}"
        echo -e "  Port-forward: kubectl port-forward -n monitoring svc/grafana 3000:80"
        echo -e "  User: admin"
        echo -e "  Password: sudo ./vps/scripts/export-secrets.sh show grafana"
    fi
    
    if [[ "$INSTALL_KEYCLOAK" == "true" ]]; then
        echo -e "\n${YELLOW}Keycloak:${NC}"
        echo -e "  Port-forward: kubectl port-forward -n security svc/keycloak 8080:80"
        echo -e "  User: admin"
        echo -e "  Password: sudo ./vps/scripts/export-secrets.sh show keycloak"
    fi
    
    if [[ "$INSTALL_ARGOCD" == "true" ]]; then
        echo -e "\n${YELLOW}Argo CD:${NC}"
        echo -e "  Port-forward: kubectl port-forward -n argocd svc/argocd-server 8443:443"
        echo -e "  URL: https://localhost:8443 (or configure Ingress)"
        echo -e "  User: admin"
        echo -e "  Password: sudo ./vps/scripts/export-secrets.sh show argocd"
        echo -e "\n${YELLOW}GitOps - Deploy your applications:${NC}"
        echo -e "  1. Add your repo to Argo CD (see docs)"
        echo -e "  2. Apply Application CRDs from your app repo"
        echo -e "  3. Argo CD will sync automatically"
    fi
    
    echo -e "\n${YELLOW}PostgreSQL:${NC}"
    echo -e "  Internal: postgresql.storage.svc.cluster.local:5432"
    echo -e "  Databases: appdb (main), keycloak"
    
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        echo -e "\n${YELLOW}Redis:${NC}"
        echo -e "  Internal: redis.database.svc.cluster.local:6379"
        echo -e "  Usage: rate limiting, caching (no persistence)"
    fi
    
    echo -e "\n${YELLOW}Next steps (see vps/docs/vps-deployment.md for details):${NC}"
    
    local step=1
    
    # Step: Configure TLS (cert-manager)
    echo -e "  ${step}. Configure TLS (cert-manager):"
    echo -e "     ${BLUE}sudo ./vps/scripts/setup-cert-manager.sh --email admin@yourdomain.com${NC}"
    ((step++))
    
    # Step: Configure Gateway API or Ingress
    if [[ "$INSTALL_GATEWAY_API" == "true" ]]; then
        echo -e "  ${step}. Configure Gateway API:"
        echo -e "     ${BLUE}sudo ./vps/scripts/setup-gateway-api.sh --domain yourdomain.com${NC}"
    else
        echo -e "  ${step}. Configure Ingress:"
        echo -e "     ${BLUE}sudo ./vps/scripts/setup-ingress.sh --domain yourdomain.com --tls${NC}"
    fi
    ((step++))
    
    # Step: Configure DNS
    echo -e "  ${step}. Configure DNS:"
    echo -e "     ${BLUE}*.yourdomain.com  A  ${EXTERNAL_IP}${NC}"
    ((step++))
    
    # Step: Configure SCM token
    echo -e "  ${step}. Configure SCM token (GitHub/GitLab):"
    echo -e "     ${BLUE}sudo ./vps/scripts/export-secrets.sh set-scm-credentials github${NC}"
    ((step++))
    
    # Step: Onboard application
    echo -e "  ${step}. Onboard your application:"
    echo -e "     ${BLUE}sudo ./vps/scripts/onboard-app.sh <app-name>${NC}"
    ((step++))
    
    # Step: Export Sealed Secrets cert
    echo -e "  ${step}. Export Sealed Secrets certificate:"
    echo -e "     ${BLUE}sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem${NC}"
    
    echo -e "\n${RED}⚠️  IMPORTANT: Credentials are stored securely in /root/.k3s-secrets/${NC}"
    echo -e "  ${BLUE}View: sudo ./vps/scripts/export-secrets.sh show${NC}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    check_root
    check_system
    install_dependencies
    generate_manifests     # Generate manifests from templates (config.env)
    install_k3s
    install_helm
    setup_helm_repos
    create_namespaces
    setup_secrets          # Generate and create K8s secrets BEFORE installing services
    install_gateway_api    # Gateway API with NGINX Gateway Fabric
    install_postgresql
    create_keycloak_database  # Create Keycloak DB after PostgreSQL is ready
    install_keycloak
    install_prometheus
    install_grafana
    install_redis
    install_sealed_secrets
    install_argocd
    install_argocd_image_updater
    setup_argocd_autodiscover
    setup_postgres_backup
    apply_network_policies
    print_summary
}

main "$@"
