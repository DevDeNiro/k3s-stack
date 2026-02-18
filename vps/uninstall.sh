#!/bin/bash
set -uo pipefail

# =============================================================================
# K3s VPS Uninstallation Script
# Cleanly removes all resources created by install.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Set KUBECONFIG for k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# SECURITY: Secrets are stored in /root/
SECRETS_DIR="/root/.k3s-secrets"

# Options
UNINSTALL_K3S="${UNINSTALL_K3S:-false}"
UNINSTALL_HELM="${UNINSTALL_HELM:-false}"
REMOVE_SECRETS="${REMOVE_SECRETS:-true}"
FORCE="${FORCE:-false}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}         K3s VPS Uninstallation - Clean Removal                ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all              Remove everything including K3s and Helm"
    echo "  --k3s              Also uninstall K3s itself"
    echo "  --helm             Also uninstall Helm"
    echo "  --keep-secrets     Keep local secrets (~/.k3s-secrets)"
    echo "  --force            Skip confirmation prompts"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "By default, only Helm releases and namespaces are removed."
    echo "K3s and Helm binaries are kept for future use."
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            UNINSTALL_K3S=true
            UNINSTALL_HELM=true
            shift
            ;;
        --k3s)
            UNINSTALL_K3S=true
            shift
            ;;
        --helm)
            UNINSTALL_HELM=true
            shift
            ;;
        --keep-secrets)
            REMOVE_SECRETS=false
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

confirm_uninstall() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}This will remove the following:${NC}"
    echo -e "  - All Helm releases (grafana, prometheus, keycloak, postgresql, ingress-nginx, postgres-backup)"
    echo -e "  - Namespaces: storage, security, monitoring, ingress-nginx"
    
    if [[ "$REMOVE_SECRETS" == "true" ]]; then
        echo -e "  - Local secrets: ${SECRETS_DIR}/"
    fi
    
    if [[ "$UNINSTALL_K3S" == "true" ]]; then
        echo -e "  - ${RED}K3s cluster (ALL DATA WILL BE LOST)${NC}"
    fi
    
    if [[ "$UNINSTALL_HELM" == "true" ]]; then
        echo -e "  - Helm binary"
    fi
    
    echo ""
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Check if K3s is running
# -----------------------------------------------------------------------------
check_k3s() {
    if ! command -v k3s &> /dev/null; then
        echo -e "${YELLOW}K3s is not installed, skipping Kubernetes cleanup${NC}"
        return 1
    fi
    
    if ! kubectl get nodes &> /dev/null 2>&1; then
        echo -e "${YELLOW}K3s is not running or not accessible, skipping Kubernetes cleanup${NC}"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Uninstall Helm releases
# -----------------------------------------------------------------------------
uninstall_helm_releases() {
    echo -e "\n${YELLOW}>>> Removing Helm releases...${NC}"
    
    if ! command -v helm &> /dev/null; then
        echo -e "${YELLOW}Helm not found, skipping Helm releases removal${NC}"
        return 0
    fi
    
    # Order matters: remove dependent services first
    local releases=(
        "postgres-backup:storage"
        "grafana:monitoring"
        "prometheus:monitoring"
        "postgresql:storage"
        "ingress-nginx:ingress-nginx"
    )
    
    for release_ns in "${releases[@]}"; do
        local release="${release_ns%%:*}"
        local namespace="${release_ns##*:}"
        
        if helm status "$release" -n "$namespace" &> /dev/null; then
            echo -e "  Removing ${BLUE}$release${NC} from ${BLUE}$namespace${NC}..."
            helm uninstall "$release" -n "$namespace" --wait --timeout 3m 2>/dev/null || true
            echo -e "  ${GREEN}✓ $release removed${NC}"
        else
            echo -e "  ${YELLOW}⚠ $release not found in $namespace${NC}"
        fi
    done
    
    # Remove Keycloak (deployed via manifest, not Helm)
    if kubectl get statefulset keycloak -n security &> /dev/null; then
        echo -e "  Removing ${BLUE}keycloak${NC} from ${BLUE}security${NC}..."
        kubectl delete statefulset keycloak -n security --timeout=120s 2>/dev/null || true
        kubectl delete service keycloak keycloak-headless -n security 2>/dev/null || true
        echo -e "  ${GREEN}✓ keycloak removed${NC}"
    else
        echo -e "  ${YELLOW}⚠ keycloak not found in security${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Remove PVCs (Persistent Volume Claims)
# -----------------------------------------------------------------------------
remove_pvcs() {
    echo -e "\n${YELLOW}>>> Removing Persistent Volume Claims...${NC}"
    
    local namespaces=("storage" "security" "monitoring")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null 2>&1; then
            local pvcs
            pvcs=$(kubectl get pvc -n "$ns" -o name 2>/dev/null || true)
            if [[ -n "$pvcs" ]]; then
                echo -e "  Removing PVCs in ${BLUE}$ns${NC}..."
                kubectl delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true
            fi
        fi
    done
    
    echo -e "${GREEN}✓ PVCs removed${NC}"
}

# -----------------------------------------------------------------------------
# Remove namespaces
# -----------------------------------------------------------------------------
remove_namespaces() {
    echo -e "\n${YELLOW}>>> Removing namespaces...${NC}"
    
    local namespaces=("storage" "security" "monitoring" "ingress-nginx")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null 2>&1; then
            echo -e "  Removing namespace ${BLUE}$ns${NC}..."
            kubectl delete namespace "$ns" --timeout=120s 2>/dev/null || true
            echo -e "  ${GREEN}✓ $ns removed${NC}"
        else
            echo -e "  ${YELLOW}⚠ Namespace $ns not found${NC}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Remove Helm repositories
# -----------------------------------------------------------------------------
remove_helm_repos() {
    echo -e "\n${YELLOW}>>> Removing Helm repositories...${NC}"
    
    if ! command -v helm &> /dev/null; then
        return 0
    fi
    
    local repos=("bitnami" "prometheus-community" "grafana" "ingress-nginx")
    
    for repo in "${repos[@]}"; do
        if helm repo list 2>/dev/null | grep -q "^$repo"; then
            helm repo remove "$repo" 2>/dev/null || true
            echo -e "  ${GREEN}✓ $repo removed${NC}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Remove local secrets
# -----------------------------------------------------------------------------
remove_local_secrets() {
    if [[ "$REMOVE_SECRETS" != "true" ]]; then
        echo -e "\n${YELLOW}>>> Keeping local secrets (--keep-secrets)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Removing local secrets...${NC}"
    
    if [[ -d "$SECRETS_DIR" ]]; then
        rm -rf "$SECRETS_DIR"
        echo -e "${GREEN}✓ ${SECRETS_DIR} removed${NC}"
    else
        echo -e "${YELLOW}⚠ ${SECRETS_DIR} not found${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Uninstall K3s
# -----------------------------------------------------------------------------
uninstall_k3s() {
    if [[ "$UNINSTALL_K3S" != "true" ]]; then
        echo -e "\n${YELLOW}>>> Keeping K3s (use --k3s or --all to remove)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Uninstalling K3s...${NC}"
    
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
        echo -e "${GREEN}✓ K3s uninstalled${NC}"
    else
        echo -e "${YELLOW}⚠ K3s uninstall script not found${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Uninstall Helm
# -----------------------------------------------------------------------------
uninstall_helm() {
    if [[ "$UNINSTALL_HELM" != "true" ]]; then
        echo -e "\n${YELLOW}>>> Keeping Helm (use --helm or --all to remove)${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Uninstalling Helm...${NC}"
    
    if command -v helm &> /dev/null; then
        local helm_path
        helm_path=$(which helm)
        rm -f "$helm_path"
        echo -e "${GREEN}✓ Helm removed${NC}"
    else
        echo -e "${YELLOW}⚠ Helm not found${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Print summary
# -----------------------------------------------------------------------------
print_summary() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Uninstallation Complete!                             ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    if [[ "$UNINSTALL_K3S" == "true" ]]; then
        echo -e "\n${GREEN}✓ K3s cluster has been completely removed${NC}"
        echo -e "  To reinstall, run: ${BLUE}./vps/install.sh${NC}"
    else
        echo -e "\n${YELLOW}K3s is still installed.${NC}"
        echo -e "  Current nodes:"
        kubectl get nodes 2>/dev/null || echo "  (K3s not running)"
        echo -e "\n  To completely remove K3s, run: ${BLUE}$0 --k3s${NC}"
    fi
    
    if [[ "$REMOVE_SECRETS" != "true" ]]; then
        echo -e "\n${YELLOW}Local secrets were preserved in ${SECRETS_DIR}${NC}"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    check_root
    confirm_uninstall
    
    if check_k3s; then
        uninstall_helm_releases
        remove_pvcs
        remove_namespaces
        remove_helm_repos
    fi
    
    remove_local_secrets
    uninstall_k3s
    uninstall_helm
    print_summary
}

main "$@"
