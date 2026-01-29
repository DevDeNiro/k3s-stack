#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s VPS Secrets Export
# Securely export secrets on-demand without persistent storage in user home
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Secrets are stored securely in /root/
ROOT_SECRETS_DIR="/root/.k3s-secrets"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: sudo $0 <command> [options]"
    echo ""
    echo "Securely export K3s secrets on-demand."
    echo ""
    echo "Commands:"
    echo "  show                     Display credentials (one-time view)"
    echo "  show <service>           Display specific service credentials"
    echo "                           Services: postgres, keycloak, grafana, argocd"
    echo ""
    echo "  export-cert <dest>       Export sealed-secrets public cert to <dest>"
    echo "                           Example: sudo $0 export-cert /tmp/cert.pem"
    echo ""
    echo "  export-kubeconfig <app> <env> <dest>"
    echo "                           Export CI/CD kubeconfig to <dest>"
    echo "                           Example: sudo $0 export-kubeconfig coterie alpha /tmp/kc.yaml"
    echo ""
    echo "  fetch-from-k8s <secret> <namespace>"
    echo "                           Fetch secret directly from Kubernetes"
    echo "                           Example: sudo $0 fetch-from-k8s postgresql-secret storage"
    echo ""
    echo "  set-github-token         Securely set GitHub token for ArgoCD auto-discovery"
    echo "                           (prompts for token, avoids shell history)"
    echo ""
    echo "Security notes:"
    echo "  - Credentials are stored in /root/.k3s-secrets/ (root access only)"
    echo "  - Exported files should be deleted after use"
    echo "  - Use 'show' to view without creating files"
    exit 0
}

# =============================================================================
# Check root
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run with sudo${NC}"
        echo "Usage: sudo $0 <command>"
        exit 1
    fi
}

# =============================================================================
# Show credentials (display only, no file created)
# =============================================================================
show_credentials() {
    local service="${1:-all}"
    local secrets_file="${ROOT_SECRETS_DIR}/credentials.env"
    
    if [[ ! -f "$secrets_file" ]]; then
        echo -e "${RED}Error: Credentials file not found at ${secrets_file}${NC}"
        echo -e "${YELLOW}Run ./vps/install.sh first${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         K3s Credentials (one-time display)                    ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    case "$service" in
        all)
            cat "$secrets_file"
            ;;
        postgres|postgresql)
            grep -E "^POSTGRES_" "$secrets_file" || echo "No PostgreSQL credentials found"
            ;;
        keycloak)
            grep -E "^KEYCLOAK_" "$secrets_file" || echo "No Keycloak credentials found"
            ;;
        grafana)
            grep -E "^GRAFANA_" "$secrets_file" || echo "No Grafana credentials found"
            ;;
        argocd|argo)
            grep -E "^ARGOCD_" "$secrets_file" || echo "No ArgoCD credentials found"
            ;;
        *)
            # Check for app-specific secrets
            local app_file="${ROOT_SECRETS_DIR}/${service}.env"
            if [[ -f "$app_file" ]]; then
                cat "$app_file"
            else
                echo -e "${RED}Unknown service: $service${NC}"
                echo "Valid services: postgres, keycloak, grafana, argocd"
                echo "Or app name if onboarded"
                exit 1
            fi
            ;;
    esac
    
    echo ""
    echo -e "${YELLOW}⚠️  These credentials are displayed once. Do not share or screenshot.${NC}"
}

# =============================================================================
# Export sealed-secrets certificate
# =============================================================================
export_cert() {
    local dest="${1:-}"
    
    if [[ -z "$dest" ]]; then
        echo -e "${RED}Error: Destination path required${NC}"
        echo "Usage: sudo $0 export-cert /path/to/cert.pem"
        exit 1
    fi
    
    local cert_file="${ROOT_SECRETS_DIR}/sealed-secrets-pub.pem"
    
    # Fetch fresh cert from cluster
    echo -e "${YELLOW}>>> Fetching certificate from Sealed Secrets controller...${NC}"
    
    # Method 1: Try kubeseal if available
    if command -v kubeseal &>/dev/null; then
        kubeseal --fetch-cert \
            --controller-name=sealed-secrets-controller \
            --controller-namespace=kube-system \
            > "$cert_file" 2>/dev/null
    else
        # Method 2: Extract cert directly from the controller's secret
        # The secret name starts with 'sealed-secrets-key'
        local secret_name
        secret_name=$(kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [[ -z "$secret_name" ]]; then
            # Fallback: find any sealed-secrets-key secret
            secret_name=$(kubectl get secrets -n kube-system -o name 2>/dev/null | grep sealed-secrets-key | head -1 | cut -d'/' -f2)
        fi
        
        if [[ -n "$secret_name" ]]; then
            kubectl get secret -n kube-system "$secret_name" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$cert_file" 2>/dev/null
        else
            echo -e "${RED}Error: Could not find Sealed Secrets key${NC}"
            echo -e "${YELLOW}Make sure sealed-secrets controller is running:${NC}"
            echo -e "  kubectl get pods -n kube-system | grep sealed"
            exit 1
        fi
    fi
    
    # Verify cert was fetched
    if [[ ! -s "$cert_file" ]]; then
        echo -e "${RED}Error: Certificate file is empty${NC}"
        exit 1
    fi
    
    # Copy to destination
    cp "$cert_file" "$dest"
    
    # Set ownership to the real user if using sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$dest"
    fi
    chmod 644 "$dest"  # Public cert can be readable
    
    echo -e "${GREEN}✓ Certificate exported to: $dest${NC}"
    echo ""
    echo -e "${YELLOW}Usage on local machine:${NC}"
    echo -e "  scp user@vps:$dest ~/.k3s-secrets/"
    echo -e "  kubeseal --cert ~/.k3s-secrets/sealed-secrets-pub.pem < secret.yaml"
    echo ""
    echo -e "${YELLOW}⚠️  Delete the exported file after copying:${NC}"
    echo -e "  rm $dest"
}

# =============================================================================
# Export kubeconfig for CI/CD
# =============================================================================
export_kubeconfig() {
    local app="${1:-}"
    local env="${2:-}"
    local dest="${3:-}"
    
    if [[ -z "$app" || -z "$env" || -z "$dest" ]]; then
        echo -e "${RED}Error: App, environment, and destination required${NC}"
        echo "Usage: sudo $0 export-kubeconfig <app> <env> /path/to/kubeconfig"
        exit 1
    fi
    
    local kc_file="${ROOT_SECRETS_DIR}/kubeconfigs/${app}-${env}.kubeconfig"
    
    if [[ ! -f "$kc_file" ]]; then
        echo -e "${RED}Error: Kubeconfig not found: $kc_file${NC}"
        echo -e "${YELLOW}Run: sudo ./vps/scripts/onboard-app.sh $app${NC}"
        exit 1
    fi
    
    cp "$kc_file" "$dest"
    
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$dest"
    fi
    chmod 600 "$dest"
    
    echo -e "${GREEN}✓ Kubeconfig exported to: $dest${NC}"
    echo ""
    echo -e "${YELLOW}For GitLab CI, encode as base64:${NC}"
    echo -e "  base64 -i $dest"
    echo ""
    echo -e "${YELLOW}⚠️  Delete after use:${NC}"
    echo -e "  rm $dest"
}

# =============================================================================
# Fetch secret directly from Kubernetes (no file storage)
# =============================================================================
fetch_from_k8s() {
    local secret="${1:-}"
    local namespace="${2:-}"
    
    if [[ -z "$secret" || -z "$namespace" ]]; then
        echo -e "${RED}Error: Secret name and namespace required${NC}"
        echo "Usage: sudo $0 fetch-from-k8s <secret-name> <namespace>"
        exit 1
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Secret: $secret (namespace: $namespace)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Get all keys and decode them
    local keys
    keys=$(kubectl get secret "$secret" -n "$namespace" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null)
    
    if [[ -z "$keys" ]]; then
        echo -e "${RED}Secret not found or empty${NC}"
        exit 1
    fi
    
    for key in $keys; do
        local value
        value=$(kubectl get secret "$secret" -n "$namespace" -o jsonpath="{.data.$key}" | base64 -d 2>/dev/null || echo "[binary data]")
        echo -e "${GREEN}$key${NC}=$value"
    done
    
    echo ""
    echo -e "${YELLOW}⚠️  Values displayed once. Do not share.${NC}"
}

# =============================================================================
# Set GitHub token securely (avoids shell history)
# =============================================================================
set_github_token() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         Set SCM Token for ArgoCD Auto-Discovery               ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}This will create/update the scm-token secret in ArgoCD namespace.${NC}"
    echo -e "${YELLOW}The token needs 'repo' scope for private repositories.${NC}"
    echo ""
    
    # Read token securely (hidden input)
    echo -n "Enter GitHub token (ghp_xxx): "
    read -rs github_token
    echo ""  # New line after hidden input
    
    if [[ -z "$github_token" ]]; then
        echo -e "${RED}Error: Token cannot be empty${NC}"
        exit 1
    fi
    
    if [[ ! "$github_token" =~ ^ghp_ ]]; then
        echo -e "${YELLOW}Warning: Token doesn't start with 'ghp_' - are you sure it's correct?${NC}"
        echo -n "Continue anyway? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
    
    # Use temporary file method to avoid token in process list
    local tmp_file
    tmp_file=$(mktemp)
    chmod 600 "$tmp_file"
    echo -n "$github_token" > "$tmp_file"
    
    # Create/update secret (scm-token is referenced by ApplicationSet)
    kubectl delete secret scm-token -n argocd 2>/dev/null || true
    kubectl create secret generic scm-token -n argocd --from-file=token="$tmp_file"
    
    # Securely remove temp file
    shred -u "$tmp_file" 2>/dev/null || rm -f "$tmp_file"
    
    echo ""
    echo -e "${GREEN}✓ SCM token configured successfully${NC}"
    echo -e "${YELLOW}ArgoCD will now be able to scan your repositories.${NC}"
}

# =============================================================================
# Main
# =============================================================================
main() {
    local command="${1:-}"
    
    case "$command" in
        show)
            check_root
            show_credentials "${2:-all}"
            ;;
        export-cert)
            check_root
            export_cert "${2:-}"
            ;;
        export-kubeconfig)
            check_root
            export_kubeconfig "${2:-}" "${3:-}" "${4:-}"
            ;;
        fetch-from-k8s|fetch)
            check_root
            fetch_from_k8s "${2:-}" "${3:-}"
            ;;
        set-github-token)
            check_root
            set_github_token
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            usage
            ;;
    esac
}

main "$@"
