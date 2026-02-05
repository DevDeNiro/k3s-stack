#!/bin/bash
set -euo pipefail

# =============================================================================
# Cert-Manager Installation Script
# Installs cert-manager for automated TLS certificate management
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$(dirname "$SCRIPT_DIR")"

# Set KUBECONFIG for k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}         Cert-Manager Installation for K3s VPS                 ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# -----------------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo -e "\n${YELLOW}>>> Checking prerequisites...${NC}"
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found${NC}"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}Error: helm not found${NC}"
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites OK${NC}"
}

# -----------------------------------------------------------------------------
# Add Helm repository
# -----------------------------------------------------------------------------
add_helm_repo() {
    echo -e "\n${YELLOW}>>> Adding cert-manager Helm repository...${NC}"
    
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    
    echo -e "${GREEN}✓ Helm repository added${NC}"
}

# -----------------------------------------------------------------------------
# Create namespace
# -----------------------------------------------------------------------------
create_namespace() {
    echo -e "\n${YELLOW}>>> Creating cert-manager namespace...${NC}"
    
    if [[ -f "$VPS_DIR/namespaces/cert-manager.yaml" ]]; then
        kubectl apply -f "$VPS_DIR/namespaces/cert-manager.yaml"
    else
        kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    echo -e "${GREEN}✓ Namespace created${NC}"
}

# -----------------------------------------------------------------------------
# Install cert-manager CRDs
# -----------------------------------------------------------------------------
install_crds() {
    echo -e "\n${YELLOW}>>> Installing cert-manager CRDs...${NC}"
    
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.1/cert-manager.crds.yaml
    
    echo -e "${GREEN}✓ CRDs installed${NC}"
}

# -----------------------------------------------------------------------------
# Install cert-manager
# -----------------------------------------------------------------------------
install_cert_manager() {
    echo -e "\n${YELLOW}>>> Installing cert-manager via Helm...${NC}"
    
    # Check if already installed
    if helm list -n cert-manager | grep -q cert-manager; then
        echo -e "${YELLOW}⚠ cert-manager already installed, upgrading...${NC}"
        helm upgrade cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --version v1.14.1 \
            --set installCRDs=false \
            --set global.leaderElection.namespace=cert-manager
    else
        helm install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --version v1.14.1 \
            --set installCRDs=false \
            --set global.leaderElection.namespace=cert-manager
    fi
    
    echo -e "${GREEN}✓ cert-manager installed${NC}"
}

# -----------------------------------------------------------------------------
# Wait for cert-manager to be ready
# -----------------------------------------------------------------------------
wait_for_cert_manager() {
    echo -e "\n${YELLOW}>>> Waiting for cert-manager to be ready...${NC}"
    
    kubectl wait --for=condition=Available --timeout=300s \
        deployment/cert-manager -n cert-manager
    
    kubectl wait --for=condition=Available --timeout=300s \
        deployment/cert-manager-webhook -n cert-manager
    
    kubectl wait --for=condition=Available --timeout=300s \
        deployment/cert-manager-cainjector -n cert-manager
    
    echo -e "${GREEN}✓ cert-manager is ready${NC}"
}

# -----------------------------------------------------------------------------
# Generate manifests from templates
# -----------------------------------------------------------------------------
generate_manifests() {
    echo -e "\n${YELLOW}>>> Generating manifests from templates...${NC}"
    
    if [[ -f "$SCRIPT_DIR/apply-config.sh" && -f "$VPS_DIR/config.env" ]]; then
        bash "$SCRIPT_DIR/apply-config.sh"
    else
        echo -e "${YELLOW}⚠ config.env not found, using existing manifests${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Create ClusterIssuers
# -----------------------------------------------------------------------------
create_cluster_issuers() {
    echo -e "\n${YELLOW}>>> Creating Let's Encrypt ClusterIssuers...${NC}"
    
    if [[ -f "$VPS_DIR/manifests/cert-manager-issuers.yaml" ]]; then
        kubectl apply -f "$VPS_DIR/manifests/cert-manager-issuers.yaml"
        echo -e "${GREEN}✓ ClusterIssuers created${NC}"
    else
        echo -e "${YELLOW}⚠ cert-manager-issuers.yaml not found, skipping${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Verify installation
# -----------------------------------------------------------------------------
verify_installation() {
    echo -e "\n${YELLOW}>>> Verifying installation...${NC}"
    
    echo -e "\n${BLUE}Cert-Manager Pods:${NC}"
    kubectl get pods -n cert-manager
    
    echo -e "\n${BLUE}ClusterIssuers:${NC}"
    kubectl get clusterissuers
    
    echo -e "${GREEN}✓ Installation verified${NC}"
}

# -----------------------------------------------------------------------------
# Print next steps
# -----------------------------------------------------------------------------
print_next_steps() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Cert-Manager successfully installed!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}📋 Next Steps:${NC}"
    echo -e "1. Add annotations to your Ingress resources:"
    echo -e "   ${BLUE}cert-manager.io/cluster-issuer: letsencrypt-prod${NC}"
    echo -e "\n2. Add TLS section to Ingress spec:"
    echo -e "   ${BLUE}tls:${NC}"
    echo -e "   ${BLUE}  - secretName: your-app-tls${NC}"
    echo -e "   ${BLUE}    hosts:${NC}"
    echo -e "   ${BLUE}      - your-domain.com${NC}"
    echo -e "\n3. cert-manager will automatically:"
    echo -e "   - Request certificate from Let's Encrypt"
    echo -e "   - Solve HTTP-01 challenge"
    echo -e "   - Store certificate in the specified secret"
    echo -e "   - Auto-renew certificates before expiration"
    echo -e "\n${YELLOW}💡 Tip:${NC} Use ${BLUE}letsencrypt-staging${NC} for testing to avoid rate limits"
    echo -e "\n${YELLOW}📖 Available ClusterIssuers:${NC}"
    echo -e "   - ${BLUE}letsencrypt-staging${NC} (for testing)"
    echo -e "   - ${BLUE}letsencrypt-prod${NC} (for production)"
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------
main() {
    check_prerequisites
    generate_manifests
    add_helm_repo
    create_namespace
    install_crds
    install_cert_manager
    wait_for_cert_manager
    create_cluster_issuers
    verify_installation
    print_next_steps
}

main "$@"
