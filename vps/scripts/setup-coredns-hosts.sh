#!/bin/bash
set -euo pipefail

# =============================================================================
# Configure CoreDNS Internal Host Resolution
# Adds entries to CoreDNS NodeHosts for hairpin NAT resolution
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$(dirname "$SCRIPT_DIR")/config.env"

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: sudo $0 [options]"
    echo ""
    echo "Configure CoreDNS to resolve internal hostnames (hairpin NAT fix)."
    echo "This allows pods to reach services via their external hostnames."
    echo ""
    echo "Options:"
    echo "  --domain <domain>    Override domain from config.env"
    echo "  --show               Show current CoreDNS NodeHosts configuration"
    echo "  --add <ip> <host>    Manually add a host entry"
    echo "  --remove <host>      Remove a host entry"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0                           # Auto-configure from config.env"
    echo "  sudo $0 --domain example.com      # Use specific domain"
    echo "  sudo $0 --show                    # Show current config"
    echo "  sudo $0 --add 10.43.1.5 auth.example.com"
    exit 0
}

# =============================================================================
# Check root
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run with sudo${NC}"
        exit 1
    fi
}

# =============================================================================
# Show current CoreDNS hosts
# =============================================================================
show_hosts() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         CoreDNS NodeHosts Configuration                       ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local hosts
    hosts=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.NodeHosts}' 2>/dev/null || echo "(empty)")
    
    if [[ -z "$hosts" || "$hosts" == "(empty)" ]]; then
        echo -e "${YELLOW}No custom hosts configured${NC}"
    else
        echo "$hosts"
    fi
    echo ""
}

# =============================================================================
# Add host entry
# =============================================================================
add_host_entry() {
    local ip="$1"
    local hostname="$2"
    
    echo -e "${YELLOW}>>> Adding ${hostname} → ${ip} to CoreDNS...${NC}"
    
    # Get current hosts
    local current_hosts
    current_hosts=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.NodeHosts}' 2>/dev/null || echo "")
    
    # Check if entry already exists
    if echo "$current_hosts" | grep -q "$hostname"; then
        echo -e "${GREEN}✓ ${hostname} already configured in CoreDNS${NC}"
        return 0
    fi
    
    # Create patch file with proper YAML formatting
    local patch_file
    patch_file=$(mktemp)
    
    cat > "$patch_file" <<EOF
data:
  NodeHosts: |
$(echo "$current_hosts" | sed 's/^/    /')
    ${ip} ${hostname}
EOF
    
    # Apply patch
    kubectl patch configmap coredns -n kube-system --type=strategic --patch-file="$patch_file"
    rm -f "$patch_file"
    
    # Restart CoreDNS
    kubectl rollout restart deployment coredns -n kube-system
    kubectl rollout status deployment coredns -n kube-system --timeout=60s
    
    echo -e "${GREEN}✓ CoreDNS configured: ${hostname} → ${ip}${NC}"
}

# =============================================================================
# Remove host entry
# =============================================================================
remove_host_entry() {
    local hostname="$1"
    
    echo -e "${YELLOW}>>> Removing ${hostname} from CoreDNS...${NC}"
    
    # Get current hosts
    local current_hosts
    current_hosts=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.NodeHosts}' 2>/dev/null || echo "")
    
    # Remove the line containing the hostname
    local new_hosts
    new_hosts=$(echo "$current_hosts" | grep -v "$hostname" || true)
    
    # Create patch file
    local patch_file
    patch_file=$(mktemp)
    
    cat > "$patch_file" <<EOF
data:
  NodeHosts: |
$(echo "$new_hosts" | sed 's/^/    /')
EOF
    
    # Apply patch
    kubectl patch configmap coredns -n kube-system --type=strategic --patch-file="$patch_file"
    rm -f "$patch_file"
    
    # Restart CoreDNS
    kubectl rollout restart deployment coredns -n kube-system
    kubectl rollout status deployment coredns -n kube-system --timeout=60s
    
    echo -e "${GREEN}✓ Removed ${hostname} from CoreDNS${NC}"
}

# =============================================================================
# Auto-configure from config.env
# =============================================================================
auto_configure() {
    local domain="${1:-}"
    
    # Load domain from config if not provided
    if [[ -z "$domain" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE"
            domain="${DOMAIN:-}"
        fi
    fi
    
    if [[ -z "$domain" ]]; then
        echo -e "${RED}Error: DOMAIN not set. Use --domain or set it in config.env${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         Configuring CoreDNS for ${domain}                     ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Configure Keycloak (auth.<domain>)
    local keycloak_ip
    keycloak_ip=$(kubectl get svc keycloak -n security -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    
    if [[ -n "$keycloak_ip" ]]; then
        add_host_entry "$keycloak_ip" "auth.${domain}"
    else
        echo -e "${YELLOW}⚠ Keycloak service not found, skipping auth.${domain}${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ CoreDNS configuration complete${NC}"
    echo ""
    show_hosts
}

# =============================================================================
# Main
# =============================================================================
main() {
    local command="${1:-auto}"
    
    case "$command" in
        --show|-s)
            check_root
            show_hosts
            ;;
        --add|-a)
            check_root
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                echo -e "${RED}Error: --add requires IP and hostname${NC}"
                echo "Usage: sudo $0 --add <ip> <hostname>"
                exit 1
            fi
            add_host_entry "$2" "$3"
            ;;
        --remove|-r)
            check_root
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --remove requires hostname${NC}"
                echo "Usage: sudo $0 --remove <hostname>"
                exit 1
            fi
            remove_host_entry "$2"
            ;;
        --domain|-d)
            check_root
            auto_configure "${2:-}"
            ;;
        -h|--help|help)
            usage
            ;;
        auto|"")
            check_root
            auto_configure ""
            ;;
        *)
            echo -e "${RED}Unknown option: $command${NC}"
            usage
            ;;
    esac
}

main "$@"
