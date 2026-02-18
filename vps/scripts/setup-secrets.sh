#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s VPS Secrets Setup
# Generates secure random passwords and creates Kubernetes Secrets
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Set KUBECONFIG for k3s (required for kubectl)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# SECURITY: Secrets are stored in /root/ (only root can access)
# Use ./vps/scripts/export-secrets.sh to safely export specific secrets
SECRETS_DIR="/root/.k3s-secrets"
SECRETS_FILE="${SECRETS_DIR}/credentials.env"

# -----------------------------------------------------------------------------
# Generate secure random password
# -----------------------------------------------------------------------------
generate_password() {
    local length="${1:-32}"
    # Use /dev/urandom for cryptographically secure randomness
    # Use only alphanumeric to avoid shell escaping issues in heredocs/YAML
    # Note: 'head' closes pipe early causing SIGPIPE; use subshell to isolate
    (LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom || true) | head -c "$length"
}

# -----------------------------------------------------------------------------
# Create secrets directory
# -----------------------------------------------------------------------------
setup_secrets_dir() {
    echo -e "${YELLOW}>>> Setting up secrets directory...${NC}"
    
    if [[ ! -d "$SECRETS_DIR" ]]; then
        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"  # Only root can access
        echo -e "${GREEN}✓ Created $SECRETS_DIR${NC}"
    fi
    
    # Initialize or clear credentials file
    : > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"  # Only root can read/write
}

# -----------------------------------------------------------------------------
# Generate all passwords
# -----------------------------------------------------------------------------
generate_all_passwords() {
    echo -e "${YELLOW}>>> Generating secure passwords...${NC}"
    
    # PostgreSQL
    POSTGRES_ADMIN_PASSWORD=$(generate_password 32)
    POSTGRES_USER_PASSWORD=$(generate_password 32)
    
    # Keycloak
    KEYCLOAK_ADMIN_PASSWORD=$(generate_password 24)
    KEYCLOAK_DB_PASSWORD=$(generate_password 32)
    
    # Grafana
    GRAFANA_ADMIN_PASSWORD=$(generate_password 24)
    
    # Argo CD
    ARGOCD_ADMIN_PASSWORD=$(generate_password 24)
    
    echo -e "${GREEN}✓ Passwords generated${NC}"
}

# -----------------------------------------------------------------------------
# Save credentials to file
# -----------------------------------------------------------------------------
save_credentials() {
    echo -e "${YELLOW}>>> Saving credentials to $SECRETS_FILE...${NC}"
    
    cat > "$SECRETS_FILE" << EOF
# =============================================================================
# K3s VPS Credentials - KEEP THIS FILE SECURE
# Generated: $(date -Iseconds)
# =============================================================================

# PostgreSQL (namespace: storage)
POSTGRES_ADMIN_PASSWORD=${POSTGRES_ADMIN_PASSWORD}
POSTGRES_USER_PASSWORD=${POSTGRES_USER_PASSWORD}

# Keycloak (namespace: security)
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KEYCLOAK_DB_PASSWORD=${KEYCLOAK_DB_PASSWORD}

# Grafana (namespace: monitoring)
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}

# Argo CD (namespace: argocd)
ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}

# =============================================================================
# Access URLs (configure after ingress setup)
# =============================================================================
# Grafana: https://grafana.<your-domain>
# Keycloak: https://auth.<your-domain>
# Prometheus: https://prometheus.<your-domain>
# Argo CD: https://argocd.<your-domain>
EOF

    chmod 600 "$SECRETS_FILE"
    echo -e "${GREEN}✓ Credentials saved to $SECRETS_FILE${NC}"
}

# -----------------------------------------------------------------------------
# Create Kubernetes Secrets
# -----------------------------------------------------------------------------
create_k8s_secrets() {
    echo -e "${YELLOW}>>> Creating Kubernetes Secrets...${NC}"
    
    # Ensure namespaces exist
    kubectl create namespace storage --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # PostgreSQL Secret
    echo -e "${YELLOW}Creating postgresql-secret in storage namespace...${NC}"
    kubectl create secret generic postgresql-secret \
        --namespace storage \
        --from-literal=postgres-password="$POSTGRES_ADMIN_PASSWORD" \
        --from-literal=password="$POSTGRES_USER_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Keycloak Admin Secret
    echo -e "${YELLOW}Creating keycloak-secret in security namespace...${NC}"
    kubectl create secret generic keycloak-secret \
        --namespace security \
        --from-literal=admin-password="$KEYCLOAK_ADMIN_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Keycloak DB Secret (for external PostgreSQL connection)
    echo -e "${YELLOW}Creating keycloak-db-secret in security namespace...${NC}"
    kubectl create secret generic keycloak-db-secret \
        --namespace security \
        --from-literal=password="$KEYCLOAK_DB_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Grafana Secret
    echo -e "${YELLOW}Creating grafana-secret in monitoring namespace...${NC}"
    kubectl create secret generic grafana-secret \
        --namespace monitoring \
        --from-literal=admin-user="admin" \
        --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Argo CD namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Argo CD Admin Secret (bcrypt hash required)
    echo -e "${YELLOW}Creating argocd-secret in argocd namespace...${NC}"
    # Generate bcrypt hash for Argo CD (requires htpasswd or python)
    local argocd_bcrypt_hash
    if command -v htpasswd &> /dev/null; then
        argocd_bcrypt_hash=$(htpasswd -nbBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':')
    elif command -v python3 &> /dev/null; then
        argocd_bcrypt_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$ARGOCD_ADMIN_PASSWORD', bcrypt.gensalt(rounds=10)).decode())")
    else
        echo -e "${YELLOW}⚠ Cannot generate bcrypt hash. Install htpasswd or python3 with bcrypt.${NC}"
        echo -e "${YELLOW}  Using initial admin password from argocd-initial-admin-secret instead.${NC}"
        argocd_bcrypt_hash=""
    fi
    
    if [[ -n "$argocd_bcrypt_hash" ]]; then
        kubectl create secret generic argocd-secret \
            --namespace argocd \
            --from-literal=admin.password="$argocd_bcrypt_hash" \
            --from-literal=admin.passwordMtime="$(date +%FT%T%Z)" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    echo -e "${GREEN}✓ All Kubernetes Secrets created${NC}"
}

# -----------------------------------------------------------------------------
# Create Keycloak database in PostgreSQL
# -----------------------------------------------------------------------------
create_keycloak_database() {
    echo -e "${YELLOW}>>> Creating Keycloak database in PostgreSQL...${NC}"
    
    # Wait for PostgreSQL to be ready
    echo -e "${YELLOW}Waiting for PostgreSQL to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=300s 2>/dev/null || true
    
    # Check if PostgreSQL pod exists
    if ! kubectl get pod -n storage -l app.kubernetes.io/name=postgresql -o name | grep -q pod; then
        echo -e "${YELLOW}⚠ PostgreSQL not installed yet. Run this after PostgreSQL is deployed.${NC}"
        return 0
    fi
    
    # Create keycloak database and user
    echo -e "${YELLOW}Creating keycloak database and user...${NC}"
    kubectl exec -it -n storage postgresql-0 -- bash -c "
        PGPASSWORD='$POSTGRES_ADMIN_PASSWORD' psql -U postgres << 'EOSQL'
-- Create keycloak user if not exists
DO \\\$\\\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
        CREATE USER keycloak WITH PASSWORD '$KEYCLOAK_DB_PASSWORD';
    ELSE
        ALTER USER keycloak WITH PASSWORD '$KEYCLOAK_DB_PASSWORD';
    END IF;
END
\\\$\\\$;

-- Create keycloak database if not exists
SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
" 2>/dev/null || echo -e "${YELLOW}⚠ Could not create keycloak DB (PostgreSQL may not be ready)${NC}"
    
    echo -e "${GREEN}✓ Keycloak database setup complete${NC}"
}

# -----------------------------------------------------------------------------
# Rotate passwords safely (update DB users before changing secrets)
# -----------------------------------------------------------------------------
rotate_passwords() {
    echo -e "${YELLOW}>>> Starting password rotation...${NC}"
    
    # 1. Load OLD credentials
    if [[ ! -f "$SECRETS_FILE" ]]; then
        echo -e "${RED}Error: No existing credentials found at $SECRETS_FILE${NC}"
        echo -e "${RED}Cannot rotate without knowing current passwords.${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Loading current credentials...${NC}"
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
    OLD_POSTGRES_ADMIN_PASSWORD="$POSTGRES_ADMIN_PASSWORD"
    OLD_KEYCLOAK_DB_PASSWORD="$KEYCLOAK_DB_PASSWORD"
    
    # 2. Generate NEW passwords
    echo -e "${YELLOW}Generating new passwords...${NC}"
    NEW_POSTGRES_ADMIN_PASSWORD=$(generate_password 32)
    NEW_POSTGRES_USER_PASSWORD=$(generate_password 32)
    NEW_KEYCLOAK_ADMIN_PASSWORD=$(generate_password 24)
    NEW_KEYCLOAK_DB_PASSWORD=$(generate_password 32)
    NEW_GRAFANA_ADMIN_PASSWORD=$(generate_password 24)
    NEW_ARGOCD_ADMIN_PASSWORD=$(generate_password 24)
    
    # 3. Update PostgreSQL users with OLD admin password
    echo -e "${YELLOW}Updating PostgreSQL user passwords...${NC}"
    
    # Wait for PostgreSQL to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=120s
    
    kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$OLD_POSTGRES_ADMIN_PASSWORD" psql -U postgres <<EOSQL
-- Update postgres admin password
ALTER USER postgres WITH PASSWORD '${NEW_POSTGRES_ADMIN_PASSWORD}';

-- Update keycloak user password
DO \$\$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
        ALTER USER keycloak WITH PASSWORD '${NEW_KEYCLOAK_DB_PASSWORD}';
    END IF;
END
\$\$;
EOSQL
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error: Failed to update PostgreSQL passwords${NC}"
        echo -e "${RED}Rotation aborted. No changes made to secrets.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ PostgreSQL user passwords updated${NC}"
    
    # 4. Now update credentials file with NEW passwords
    POSTGRES_ADMIN_PASSWORD="$NEW_POSTGRES_ADMIN_PASSWORD"
    POSTGRES_USER_PASSWORD="$NEW_POSTGRES_USER_PASSWORD"
    KEYCLOAK_ADMIN_PASSWORD="$NEW_KEYCLOAK_ADMIN_PASSWORD"
    KEYCLOAK_DB_PASSWORD="$NEW_KEYCLOAK_DB_PASSWORD"
    GRAFANA_ADMIN_PASSWORD="$NEW_GRAFANA_ADMIN_PASSWORD"
    ARGOCD_ADMIN_PASSWORD="$NEW_ARGOCD_ADMIN_PASSWORD"
    
    save_credentials
    
    # 5. Update Kubernetes secrets
    create_k8s_secrets
    
    # 6. Restart services
    echo -e "${YELLOW}>>> Restarting services...${NC}"
    kubectl rollout restart statefulset/postgresql -n storage
    kubectl rollout restart deployment/keycloak -n security 2>/dev/null || \
        kubectl rollout restart statefulset/keycloak -n security 2>/dev/null || true
    kubectl rollout restart deployment/grafana -n monitoring
    
    echo -e "${GREEN}✓ Password rotation complete!${NC}"
    echo -e "${YELLOW}Waiting for services to restart...${NC}"
    
    # Wait for PostgreSQL to be ready with new password
    sleep 5
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=120s || true
    
    echo -e "\n${GREEN}✓ All services restarted with new passwords${NC}"
    echo -e "${YELLOW}View new credentials: sudo ./vps/scripts/export-secrets.sh show${NC}"
}

# -----------------------------------------------------------------------------
# Print summary
# -----------------------------------------------------------------------------
print_summary() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Secrets Setup Complete!                               ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Credentials saved to:${NC}"
    echo -e "  ${SECRETS_FILE}"
    
    echo -e "\n${YELLOW}Kubernetes Secrets created:${NC}"
    echo -e "  - postgresql-secret (namespace: storage)"
    echo -e "  - keycloak-secret (namespace: security)"
    echo -e "  - keycloak-db-secret (namespace: security)"
    echo -e "  - grafana-secret (namespace: monitoring)"
    echo -e "  - argocd-secret (namespace: argocd)"
    
    echo -e "\n${YELLOW}Quick access to credentials:${NC}"
    echo -e "  ${BLUE}cat $SECRETS_FILE${NC}"
    
    echo -e "\n${YELLOW}Verify secrets in cluster:${NC}"
    echo -e "  ${BLUE}kubectl get secrets -n storage${NC}"
    echo -e "  ${BLUE}kubectl get secrets -n security${NC}"
    echo -e "  ${BLUE}kubectl get secrets -n monitoring${NC}"
    
    echo -e "\n${RED}⚠️  IMPORTANT: Keep $SECRETS_FILE secure!${NC}"
    echo -e "${RED}    - Do not commit to git${NC}"
    echo -e "${RED}    - Backup in a secure location${NC}"
}

# -----------------------------------------------------------------------------
# Show credentials (for verification)
# -----------------------------------------------------------------------------
show_credentials() {
    if [[ -f "$SECRETS_FILE" ]]; then
        echo -e "\n${YELLOW}Current credentials:${NC}"
        echo -e "${BLUE}─────────────────────────────────────────${NC}"
        cat "$SECRETS_FILE"
        echo -e "${BLUE}─────────────────────────────────────────${NC}"
    else
        echo -e "${RED}No credentials file found at $SECRETS_FILE${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  setup     Generate passwords and create Kubernetes Secrets (default)"
    echo "  show      Display saved credentials"
    echo "  rotate    Regenerate all passwords (WARNING: will require service restart)"
    echo "  help      Show this help"
    echo ""
    echo "Environment variables:"
    echo "  SECRETS_DIR    Directory to store credentials (default: ~/.k3s-secrets)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local command="${1:-setup}"
    
    case "$command" in
        setup)
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BLUE}         K3s VPS Secrets Setup                                 ${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            
            setup_secrets_dir
            generate_all_passwords
            save_credentials
            create_k8s_secrets
            create_keycloak_database
            print_summary
            ;;
        show)
            show_credentials
            ;;
        rotate)
            echo -e "${RED}⚠️  WARNING: This will regenerate all passwords!${NC}"
            echo -e "${RED}    Services will need to be restarted.${NC}"
            read -r -p "Continue? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rotate_passwords
            else
                echo "Aborted."
            fi
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
