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
    echo "                           Example: sudo $0 export-kubeconfig myapp alpha /tmp/kc.yaml"
    echo ""
    echo "  fetch-from-k8s <secret> <namespace>"
    echo "                           Fetch secret directly from Kubernetes"
    echo "                           Example: sudo $0 fetch-from-k8s postgresql-secret storage"
    echo ""
  echo "  set-scm-credentials      Set SCM credentials for ArgoCD repository access"
    echo "                           Supports: github, gitlab"
    echo "                           Example: sudo $0 set-scm-credentials github"
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
# Set SCM credentials for ArgoCD repository access
# Supports GitHub and GitLab
# =============================================================================
set_scm_credentials() {
    local provider="${1:-}"
    
    if [[ -z "$provider" ]]; then
        echo -e "${RED}Error: Provider required${NC}"
        echo "Usage: sudo $0 set-scm-credentials <github|gitlab>"
        exit 1
    fi
    
    case "$provider" in
        github)
            set_github_credentials
            ;;
        gitlab)
            set_gitlab_credentials
            ;;
        *)
            echo -e "${RED}Error: Unknown provider '$provider'${NC}"
            echo "Supported providers: github, gitlab"
            exit 1
            ;;
    esac
}

set_github_credentials() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         Set GitHub Credentials for ArgoCD                      ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}This creates a repo-creds secret for ArgoCD to access private repos.${NC}"
    echo -e "${YELLOW}The token needs 'repo' scope (or 'Contents: read' for fine-grained).${NC}"
    echo ""
    
    # Get GitHub org/user URL
    echo -n "Enter GitHub org/user URL [https://github.com/your-org]: "
    read -r scm_url
    scm_url="${scm_url:-https://github.com/your-org}"
    
    # Read token securely (hidden input)
    echo -n "Enter GitHub token (ghp_xxx or github_pat_xxx): "
    read -rs scm_token
    echo ""
    
    if [[ -z "$scm_token" ]]; then
        echo -e "${RED}Error: Token cannot be empty${NC}"
        exit 1
    fi
    
    if [[ ! "$scm_token" =~ ^(ghp_|github_pat_) ]]; then
        echo -e "${YELLOW}Warning: Token doesn't look like a GitHub token${NC}"
        echo -n "Continue anyway? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
    
    create_repo_creds_secret "github-repo-creds" "$scm_url" "git" "$scm_token"
    
    echo -e "${GREEN}✓ GitHub repo credentials configured successfully${NC}"
    echo -e "${YELLOW}ArgoCD can now access private repos under: $scm_url${NC}"
}

set_gitlab_credentials() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}         Set GitLab Credentials for ArgoCD                      ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}This creates a repo-creds secret for ArgoCD to access private repos.${NC}"
    echo -e "${YELLOW}The token needs 'read_repository' scope.${NC}"
    echo ""
    
    # Get GitLab group URL
    echo -n "Enter GitLab group URL [https://gitlab.com/your-group]: "
    read -r scm_url
    
    if [[ -z "$scm_url" ]]; then
        echo -e "${RED}Error: GitLab URL required${NC}"
        exit 1
    fi
    
    # Read token securely (hidden input)
    echo -n "Enter GitLab token (glpat-xxx): "
    read -rs scm_token
    echo ""
    
    if [[ -z "$scm_token" ]]; then
        echo -e "${RED}Error: Token cannot be empty${NC}"
        exit 1
    fi
    
    if [[ ! "$scm_token" =~ ^glpat- ]]; then
        echo -e "${YELLOW}Warning: Token doesn't look like a GitLab token${NC}"
        echo -n "Continue anyway? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
    
    create_repo_creds_secret "gitlab-repo-creds" "$scm_url" "oauth2" "$scm_token"
    
    echo -e "${GREEN}✓ GitLab repo credentials configured successfully${NC}"
    echo -e "${YELLOW}ArgoCD can now access private repos under: $scm_url${NC}"
}

# Helper function to create repo-creds secret
create_repo_creds_secret() {
    local secret_name="$1"
    local url="$2"
    local username="$3"
    local password="$4"
    
    # Delete existing secret if present
    kubectl delete secret "$secret_name" -n argocd 2>/dev/null || true
    
    # Create secret with proper structure for ArgoCD repo-creds
    # See: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repository-credentials
    kubectl create secret generic "$secret_name" -n argocd \
        --from-literal=type=git \
        --from-literal=url="$url" \
        --from-literal=username="$username" \
        --from-literal=password="$password"
    
    # Add required label for ArgoCD to recognize this as repo credentials
    kubectl label secret "$secret_name" -n argocd \
        argocd.argoproj.io/secret-type=repo-creds

    # Also create scm-token mirror for ApplicationSet controller (autodiscover)
    # This is required because ApplicationSet generator uses a separate secret reference
    echo "Creating scm-token mirror..."
    kubectl create secret generic scm-token -n argocd \
        --from-literal=token="$password" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo ""
    echo -e "${BLUE}Verify with:${NC}"
    echo -e "  kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repo-creds"
    echo ""
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
        set-scm-credentials)
            check_root
            set_scm_credentials "${2:-}"
            ;;
        # Legacy alias
        set-github-token)
            check_root
            set_scm_credentials "github"
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
