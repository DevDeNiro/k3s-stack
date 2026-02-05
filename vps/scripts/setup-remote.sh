#!/bin/bash
set -euo pipefail

# =============================================================================
# Setup Remote Access to K3s VPS
# Configures local kubectl to connect to remote VPS K3s cluster
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

KUBECONFIG_DIR="${HOME}/.kube"
CONTEXT_NAME="k3s-vps"

usage() {
    echo "Usage: $0 <vps-ip> [ssh-user] [ssh-port]"
    echo ""
    echo "Arguments:"
    echo "  vps-ip      IP address or hostname of the VPS"
    echo "  ssh-user    SSH user (default: root)"
    echo "  ssh-port    SSH port (default: 22)"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100"
    echo "  $0 192.168.1.100 ubuntu"
    echo "  $0 my-vps.example.com root 2222"
    exit 1
}

# Parse arguments
VPS_IP="${1:-}"
SSH_USER="${2:-root}"
SSH_PORT="${3:-22}"

if [[ -z "$VPS_IP" ]]; then
    echo -e "${RED}Error: VPS IP is required${NC}"
    usage
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}         K3s VPS Remote Access Setup                           ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# -----------------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo -e "\n${YELLOW}>>> Checking prerequisites...${NC}"
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        echo "Install it from: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    
    if ! command -v ssh &> /dev/null; then
        echo -e "${RED}Error: ssh is not installed${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites met${NC}"
}

# -----------------------------------------------------------------------------
# Test SSH connection
# -----------------------------------------------------------------------------
test_ssh_connection() {
    echo -e "\n${YELLOW}>>> Testing SSH connection to ${SSH_USER}@${VPS_IP}:${SSH_PORT}...${NC}"
    
    if ! ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${VPS_IP}" "echo 'SSH OK'" &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to ${SSH_USER}@${VPS_IP}:${SSH_PORT}${NC}"
        echo "Make sure:"
        echo "  1. The VPS is running"
        echo "  2. SSH is enabled"
        echo "  3. Your SSH key is authorized"
        echo ""
        echo "Try: ssh -p ${SSH_PORT} ${SSH_USER}@${VPS_IP}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ SSH connection successful${NC}"
}

# -----------------------------------------------------------------------------
# Check if K3s is running on VPS
# -----------------------------------------------------------------------------
check_k3s_running() {
    echo -e "\n${YELLOW}>>> Checking if K3s is running on VPS...${NC}"
    
    if ! ssh -p "$SSH_PORT" "${SSH_USER}@${VPS_IP}" "kubectl get nodes" &> /dev/null; then
        echo -e "${RED}Error: K3s does not seem to be running on the VPS${NC}"
        echo "Run the installation script on the VPS first:"
        echo "  ssh -p ${SSH_PORT} ${SSH_USER}@${VPS_IP}"
        echo "  git clone <repo> && cd k3d-stack"
        echo "  sudo ./vps/install-k3s.sh"
        exit 1
    fi
    
    echo -e "${GREEN}✓ K3s is running${NC}"
}

# -----------------------------------------------------------------------------
# Fetch kubeconfig from VPS
# -----------------------------------------------------------------------------
fetch_kubeconfig() {
    echo -e "\n${YELLOW}>>> Fetching kubeconfig from VPS...${NC}"
    
    # Create kubeconfig directory if it doesn't exist
    mkdir -p "$KUBECONFIG_DIR"
    
    # Define target kubeconfig path
    KUBECONFIG_FILE="${KUBECONFIG_DIR}/config-${CONTEXT_NAME}"
    
    # Fetch kubeconfig
    scp -P "$SSH_PORT" "${SSH_USER}@${VPS_IP}:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_FILE"
    
    echo -e "${GREEN}✓ Kubeconfig downloaded to ${KUBECONFIG_FILE}${NC}"
}

# -----------------------------------------------------------------------------
# Update kubeconfig with correct server address
# -----------------------------------------------------------------------------
update_kubeconfig() {
    echo -e "\n${YELLOW}>>> Updating kubeconfig with VPS address...${NC}"
    
    # Replace localhost/127.0.0.1 with actual VPS IP
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/127.0.0.1/${VPS_IP}/g" "$KUBECONFIG_FILE"
        sed -i '' "s/localhost/${VPS_IP}/g" "$KUBECONFIG_FILE"
        # Update context name
        sed -i '' "s/name: default/name: ${CONTEXT_NAME}/g" "$KUBECONFIG_FILE"
    else
        # Linux
        sed -i "s/127.0.0.1/${VPS_IP}/g" "$KUBECONFIG_FILE"
        sed -i "s/localhost/${VPS_IP}/g" "$KUBECONFIG_FILE"
        sed -i "s/name: default/name: ${CONTEXT_NAME}/g" "$KUBECONFIG_FILE"
    fi
    
    # Set proper permissions
    chmod 600 "$KUBECONFIG_FILE"
    
    echo -e "${GREEN}✓ Kubeconfig updated${NC}"
}

# -----------------------------------------------------------------------------
# Test connection to cluster
# -----------------------------------------------------------------------------
test_cluster_connection() {
    echo -e "\n${YELLOW}>>> Testing connection to K3s cluster...${NC}"
    
    export KUBECONFIG="$KUBECONFIG_FILE"
    
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to K3s cluster${NC}"
        echo ""
        echo "Possible issues:"
        echo "  1. Firewall blocking port 6443"
        echo "  2. K3s API server not accessible from outside"
        echo ""
        echo "On the VPS, ensure port 6443 is open:"
        echo "  sudo ufw allow 6443/tcp"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Successfully connected to K3s cluster${NC}"
    echo ""
    kubectl get nodes
}

# -----------------------------------------------------------------------------
# Print usage instructions
# -----------------------------------------------------------------------------
print_instructions() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Setup Complete!                                       ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Kubeconfig saved to:${NC}"
    echo -e "  ${KUBECONFIG_FILE}"
    
    echo -e "\n${YELLOW}Usage:${NC}"
    echo -e "  ${BLUE}# Option 1: Set KUBECONFIG environment variable${NC}"
    echo -e "  export KUBECONFIG=${KUBECONFIG_FILE}"
    echo -e "  kubectl get pods -A"
    echo ""
    echo -e "  ${BLUE}# Option 2: Use --kubeconfig flag${NC}"
    echo -e "  kubectl --kubeconfig=${KUBECONFIG_FILE} get pods -A"
    echo ""
    echo -e "  ${BLUE}# Option 3: Merge with default kubeconfig${NC}"
    echo -e "  KUBECONFIG=~/.kube/config:${KUBECONFIG_FILE} kubectl config view --flatten > ~/.kube/config.merged"
    echo -e "  mv ~/.kube/config.merged ~/.kube/config"
    echo -e "  kubectl config use-context ${CONTEXT_NAME}"
    
    echo -e "\n${YELLOW}Quick commands:${NC}"
    echo -e "  # Check cluster status"
    echo -e "  kubectl get nodes"
    echo -e "  kubectl get pods -A"
    echo ""
    echo -e "  # Access Grafana (port-forward)"
    echo -e "  kubectl port-forward -n monitoring svc/grafana 3000:80"
    echo ""
    echo -e "  # Access Keycloak (port-forward)"
    echo -e "  kubectl port-forward -n security svc/keycloak 8080:80"
    echo ""
    echo -e "  # View logs"
    echo -e "  kubectl logs -n <namespace> -f deploy/<deployment>"
    
    echo -e "\n${YELLOW}Shell alias (add to ~/.zshrc or ~/.bashrc):${NC}"
    echo -e "  alias k-vps='kubectl --kubeconfig=${KUBECONFIG_FILE}'"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    check_prerequisites
    test_ssh_connection
    check_k3s_running
    fetch_kubeconfig
    update_kubeconfig
    test_cluster_connection
    print_instructions
}

main "$@"
