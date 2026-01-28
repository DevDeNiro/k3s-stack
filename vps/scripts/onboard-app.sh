#!/bin/bash
set -euo pipefail

# =============================================================================
# Onboard Application to K3s Stack
# One-time setup: namespace, database, Keycloak client, secrets, CI/CD access
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Set KUBECONFIG for k3s (required for kubectl)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SECURITY: Secrets are stored in /root/ (only root can access)
# Use ./vps/scripts/export-secrets.sh to safely export specific secrets
SECRETS_DIR="/root/.k3s-secrets"
SECRETS_FILE="${SECRETS_DIR}/credentials.env"

# =============================================================================
# Configuration
# =============================================================================
APP_NAME="${1:-}"
SKIP_DATABASE="${SKIP_DATABASE:-false}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: $0 <app-name>"
    echo ""
    echo "Onboard an application to K3s stack (run once per application)."
    echo ""
    echo "This script creates:"
    echo "  - Namespaces: <app>-prod and <app>-alpha with resource quotas"
    echo "  - PostgreSQL database and user"
    echo "  - Kubernetes secrets in each namespace"
    echo "  - ServiceAccount and kubeconfig for CI/CD"
    echo ""
    echo "Options (via environment variables):"
    echo "  SKIP_DATABASE=true     Skip database creation"
    echo ""
    echo "Example:"
    echo "  $0 coterie-webapp"
}

# =============================================================================
# Validation
# =============================================================================
if [[ -z "$APP_NAME" || "$APP_NAME" == "-h" || "$APP_NAME" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! "$APP_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo -e "${RED}Error: App name must be lowercase alphanumeric with hyphens only${NC}"
    exit 1
fi

# =============================================================================
# Load infrastructure secrets
# =============================================================================
load_secrets() {
    echo -e "${YELLOW}>>> Loading infrastructure secrets...${NC}"
    
    # Check multiple possible locations (sudo changes HOME)
    local possible_paths=(
        "$SECRETS_FILE"
        "/root/.k3s-secrets/credentials.env"
        "/home/ubuntu/.k3s-secrets/credentials.env"
    )
    
    local found_file=""
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" ]]; then
            found_file="$path"
            break
        fi
    done
    
    if [[ -z "$found_file" ]]; then
        echo -e "${RED}Error: Infrastructure secrets not found${NC}"
        echo -e "${YELLOW}Looked in: ${possible_paths[*]}${NC}"
        echo -e "${YELLOW}Run ./vps/install.sh first${NC}"
        exit 1
    fi
    
    source "$found_file"
    SECRETS_FILE="$found_file"
    echo -e "${GREEN}✓ Secrets loaded from $found_file${NC}"
}

# =============================================================================
# Generate secure password
# =============================================================================
generate_password() {
    # Read enough random bytes first to avoid SIGPIPE with pipefail
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "${1:-32}"
}

# =============================================================================
# Create namespaces
# =============================================================================
create_namespaces() {
    echo -e "${YELLOW}>>> Creating namespaces...${NC}"
    
    for env in prod alpha; do
        local ns="${APP_NAME}-${env}"
        local cpu_req=$( [[ "$env" == "prod" ]] && echo "2" || echo "1" )
        local mem_req=$( [[ "$env" == "prod" ]] && echo "2Gi" || echo "1Gi" )
        local cpu_lim=$( [[ "$env" == "prod" ]] && echo "4" || echo "2" )
        local mem_lim=$( [[ "$env" == "prod" ]] && echo "4Gi" || echo "2Gi" )
        local pods=$( [[ "$env" == "prod" ]] && echo "20" || echo "10" )
        
        # PSA: restricted for prod, baseline for alpha (more permissive for debugging)
        local psa_enforce=$( [[ "$env" == "prod" ]] && echo "restricted" || echo "baseline" )
        
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/environment: ${env}
    app.kubernetes.io/managed-by: k3s-stack
    # Pod Security Admission
    pod-security.kubernetes.io/enforce: ${psa_enforce}
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${ns}-quota
  namespace: ${ns}
spec:
  hard:
    requests.cpu: "${cpu_req}"
    requests.memory: "${mem_req}"
    limits.cpu: "${cpu_lim}"
    limits.memory: "${mem_lim}"
    pods: "${pods}"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: ${ns}-limits
  namespace: ${ns}
spec:
  limits:
    - default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      type: Container
EOF
        echo -e "${GREEN}✓ Namespace ${ns} created${NC}"
    done
}

# =============================================================================
# Create database
# =============================================================================
create_database() {
    if [[ "$SKIP_DATABASE" == "true" ]]; then
        echo -e "${YELLOW}>>> Skipping database creation${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}>>> Creating PostgreSQL database for ${APP_NAME}...${NC}"
    
    APP_DB_PASSWORD=$(generate_password 32)
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=120s
    
    # Use -i flag and pipe SQL via stdin to avoid heredoc issues
    # Quote identifiers with double quotes to support hyphens in names
    kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" psql -U postgres <<EOSQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_NAME}') THEN
        CREATE USER "${APP_NAME}" WITH PASSWORD '${APP_DB_PASSWORD}';
    ELSE
        ALTER USER "${APP_NAME}" WITH PASSWORD '${APP_DB_PASSWORD}';
    END IF;
END
\$\$;

SELECT 'CREATE DATABASE "${APP_NAME}" OWNER "${APP_NAME}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${APP_NAME}')\gexec

GRANT ALL PRIVILEGES ON DATABASE "${APP_NAME}" TO "${APP_NAME}";
EOSQL
    
    echo -e "${GREEN}✓ Database '${APP_NAME}' created${NC}"
    
    for env in prod alpha; do
        local ns="${APP_NAME}-${env}"
        
        # NOTE: The 'postgresql' secret is managed by Helm/SealedSecrets
        # Only create the app-specific database info secret
        kubectl create secret generic "${APP_NAME}-db" \
            --namespace "$ns" \
            --from-literal=host="postgresql.storage.svc.cluster.local" \
            --from-literal=port="5432" \
            --from-literal=database="$APP_NAME" \
            --from-literal=username="$APP_NAME" \
            --from-literal=password="$APP_DB_PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        echo -e "${GREEN}✓ Database info secret created in ${ns}${NC}"
        echo -e "${YELLOW}  ⚠ You must seal the PostgreSQL password using:${NC}"
        echo -e "${YELLOW}    ./scripts/seal-secrets.sh postgresql ${ns} --cert <cert-path>${NC}"
    done
    
    echo "${APP_NAME^^}_DB_PASSWORD=${APP_DB_PASSWORD}" >> "$APP_SECRETS_FILE"
    echo -e "${GREEN}✓ Password saved to $APP_SECRETS_FILE${NC}"
}

# =============================================================================
# Create CI/CD access
# =============================================================================
create_cicd_access() {
    echo -e "${YELLOW}>>> Creating CI/CD ServiceAccounts...${NC}"
    
    for env in prod alpha; do
        local ns="${APP_NAME}-${env}"
        local sa="deployer"
        
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa}
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${sa}-role
  namespace: ${ns}
rules:
  - apiGroups: ["", "apps", "networking.k8s.io", "batch"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${sa}-binding
  namespace: ${ns}
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: ${ns}
roleRef:
  kind: Role
  name: ${sa}-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: ${sa}-token
  namespace: ${ns}
  annotations:
    kubernetes.io/service-account.name: ${sa}
type: kubernetes.io/service-account-token
EOF
        echo -e "${GREEN}✓ ServiceAccount 'deployer' in ${ns}${NC}"
    done
    
    generate_kubeconfigs
}

generate_kubeconfigs() {
    echo -e "${YELLOW}>>> Generating CI/CD kubeconfigs...${NC}"
    
    local dir="${SECRETS_DIR}/kubeconfigs"
    mkdir -p "$dir"
    chmod 700 "$dir"  # Only root can access
    
    local server
    server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    local ca
    ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
    
    sleep 2
    
    for env in prod alpha; do
        local ns="${APP_NAME}-${env}"
        local token
        token=$(kubectl get secret deployer-token -n "$ns" -o jsonpath='{.data.token}' | base64 -d)
        
        cat > "${dir}/${APP_NAME}-${env}.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
contexts:
  - name: default
    context:
      cluster: k3s
      namespace: ${ns}
      user: deployer
current-context: default
users:
  - name: deployer
    user:
      token: ${token}
EOF
        chmod 600 "${dir}/${APP_NAME}-${env}.kubeconfig"  # Only root can read
        echo -e "${GREEN}✓ ${dir}/${APP_NAME}-${env}.kubeconfig${NC}"
    done
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    local dir="/root/.k3s-secrets/kubeconfigs"
    
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         ${APP_NAME} Onboarded!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Namespaces:${NC} ${APP_NAME}-prod, ${APP_NAME}-alpha"
    echo -e "${YELLOW}Database:${NC} ${APP_NAME} (PostgreSQL)"
    
    echo -e "\n${YELLOW}Secrets in each namespace:${NC}"
    echo -e "  • postgresql       → password"
    echo -e "  • ${APP_NAME}-db   → host, port, database, username, password"
    
    echo -e "\n${YELLOW}CI/CD Kubeconfigs (secured in /root/):${NC}"
    echo -e "  Export: sudo ./vps/scripts/export-secrets.sh export-kubeconfig ${APP_NAME} prod /tmp/kc.yaml"
    echo -e "  Export: sudo ./vps/scripts/export-secrets.sh export-kubeconfig ${APP_NAME} alpha /tmp/kc.yaml"
    
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}GitLab CI Setup:${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    echo -e "1. Encode kubeconfig:"
    echo -e "   ${BLUE}base64 -i ${dir}/${APP_NAME}-alpha.kubeconfig${NC}"
    echo -e ""
    echo -e "2. Add to GitLab CI/CD Variables:"
    echo -e "   KUBECONFIG_ALPHA (masked, protected for alpha branch)"
    echo -e "   KUBECONFIG_PROD  (masked, protected for main branch)"
    echo -e ""
    echo -e "3. .gitlab-ci.yml example:"
    echo -e "   ${BLUE}deploy:${NC}"
    echo -e "   ${BLUE}  script:${NC}"
    echo -e "   ${BLUE}    - echo \"\$KUBECONFIG_ALPHA\" | base64 -d > kubeconfig${NC}"
    echo -e "   ${BLUE}    - helm upgrade --install ${APP_NAME} ./helm/${APP_NAME}${NC}"
    echo -e "   ${BLUE}      --kubeconfig kubeconfig -n ${APP_NAME}-alpha${NC}"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         Onboarding: ${APP_NAME}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    mkdir -p "$SECRETS_DIR"
    APP_SECRETS_FILE="${SECRETS_DIR}/${APP_NAME}.env"
    : > "$APP_SECRETS_FILE"
    chmod 600 "$APP_SECRETS_FILE"  # Only root can read
    
    load_secrets
    create_namespaces
    create_database
    create_cicd_access
    print_summary
}

main