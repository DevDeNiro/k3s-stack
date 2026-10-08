#!/bin/bash
set -euo pipefail

# =============================================================================
# Onboard Application to K3s Stack
# Per-environment setup: namespace, database, secrets, optional CI/CD access
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
APP_NAME=""
TARGET_ENV="all"
TARGET_ENVS=()
SKIP_DATABASE="${SKIP_DATABASE:-false}"
SKIP_GATEWAY="${SKIP_GATEWAY:-false}"
SKIP_CICD="${SKIP_CICD:-false}"

# Subdomain overrides (optional)
# Default: alpha.<domain> for alpha env, app.<domain> for prod env
SUBDOMAIN_ALPHA="${SUBDOMAIN_ALPHA:-alpha}"
SUBDOMAIN_PROD="${SUBDOMAIN_PROD:-app}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: $0 <app-name> [--environment all|alpha|prod] [--skip-cicd]"
    echo ""
    echo "Onboard an application to K3s stack."
    echo ""
    echo "This script creates:"
    echo "  - Selected application namespace(s) with resource quotas"
    echo "  - PostgreSQL database, user, and Secret when missing"
    echo "  - GHCR and Gateway TLS resources for selected environment(s)"
    echo ""
    echo "Options:"
    echo "  --environment ENV     Target all, alpha, or prod (default: all)"
    echo "  --skip-cicd           Skip deployer ServiceAccounts and kubeconfigs"
    echo ""
    echo "Environment variables:"
    echo "  SKIP_DATABASE=true     Skip database creation"
    echo "  SKIP_GATEWAY=true      Skip Gateway TLS setup"
    echo ""
    echo "Examples:"
    echo "  $0 myapp"
    echo "  $0 myapp --environment prod --skip-cicd"
    echo "  SUBDOMAIN_ALPHA=preview SUBDOMAIN_PROD=www $0 myapp"
}

# =============================================================================
# Validation
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment|--env)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --environment requires all, alpha, or prod${NC}"
                exit 1
            fi
            TARGET_ENV="$2"
            shift 2
            ;;
        --skip-cicd)
            SKIP_CICD="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}"
            usage
            exit 1
            ;;
        *)
            if [[ -n "$APP_NAME" ]]; then
                echo -e "${RED}Error: Only one app name may be specified${NC}"
                usage
                exit 1
            fi
            APP_NAME="$1"
            shift
            ;;
    esac
done

if [[ -z "$APP_NAME" ]]; then
    usage
    exit 0
fi

if [[ ! "$APP_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo -e "${RED}Error: App name must be lowercase alphanumeric with hyphens only${NC}"
    exit 1
fi

case "$TARGET_ENV" in
    all)
        TARGET_ENVS=(alpha prod)
        ;;
    alpha|prod)
        TARGET_ENVS=("$TARGET_ENV")
        ;;
    *)
        echo -e "${RED}Error: --environment must be all, alpha, or prod${NC}"
        exit 1
        ;;
esac

for flag_name in SKIP_DATABASE SKIP_GATEWAY SKIP_CICD; do
    flag_value="${!flag_name}"
    if [[ "$flag_value" != "true" && "$flag_value" != "false" ]]; then
        echo -e "${RED}Error: ${flag_name} must be true or false${NC}"
        exit 1
    fi
done

# =============================================================================
# Load config.env for domain and other settings
# =============================================================================
load_config() {
    local config_file
    config_file="$(dirname "$SCRIPT_DIR")/config.env"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        echo -e "${GREEN}✓ Config loaded from $config_file${NC}"
    else
        echo -e "${RED}Error: config.env not found at $config_file${NC}"
        exit 1
    fi
    
    if [[ -z "${DOMAIN:-}" ]]; then
        echo -e "${RED}Error: DOMAIN not set in config.env${NC}"
        exit 1
    fi
}

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
    if [[ -z "${POSTGRES_ADMIN_PASSWORD:-}" ]]; then
        echo -e "${RED}Error: POSTGRES_ADMIN_PASSWORD is missing from infrastructure secrets${NC}"
        exit 1
    fi
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
# Database credential helpers
# =============================================================================
database_password_key() {
    local normalized_app_name="${APP_NAME^^}"
    normalized_app_name="${normalized_app_name//-/_}"
    printf '%s_%s_DB_PASSWORD' "$normalized_app_name" "${1^^}"
}

legacy_database_password_key() {
    printf '%s_%s_DB_PASSWORD' "${APP_NAME^^}" "${1^^}"
}

read_saved_database_password() {
    local current_key
    local legacy_key
    current_key=$(database_password_key "$1")
    legacy_key=$(legacy_database_password_key "$1")

    if [[ ! -f "$APP_SECRETS_FILE" ]]; then
        return 0
    fi

    awk -F= -v current_key="$current_key" -v legacy_key="$legacy_key" \
        '$1 == current_key || $1 == legacy_key { sub(/^[^=]*=/, ""); value = $0 } END { if (value != "") print value }' \
        "$APP_SECRETS_FILE"
}

save_database_password() {
    local env="$1"
    local password="$2"
    local current_key
    local legacy_key
    local temporary_file

    current_key=$(database_password_key "$env")
    legacy_key=$(legacy_database_password_key "$env")
    temporary_file=$(mktemp "${APP_SECRETS_FILE}.tmp.XXXXXX")

    if [[ -f "$APP_SECRETS_FILE" ]]; then
        awk -F= -v current_key="$current_key" -v legacy_key="$legacy_key" \
            '$1 != current_key && $1 != legacy_key' "$APP_SECRETS_FILE" > "$temporary_file"
    fi

    printf '%s=%s\n' "$current_key" "$password" >> "$temporary_file"
    chmod 600 "$temporary_file"
    mv "$temporary_file" "$APP_SECRETS_FILE"
}

database_secret_password() {
    local namespace="$1"
    kubectl get secret "${APP_NAME}-db" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null \
        | base64 -d 2>/dev/null || true
}

verify_database_password() {
    local env="$1"
    local password="$2"
    local database="$3"
    local db_user="${APP_NAME}-${env}"

    kubectl exec -n storage postgresql-0 -- env PGPASSWORD="$password" \
        psql -h 127.0.0.1 -U "$db_user" -d "$database" -Atqc 'SELECT 1' >/dev/null 2>&1
}

create_database_secret() {
    local env="$1"
    local password="$2"
    local db_name="${APP_NAME}-${env}"
    local namespace="${APP_NAME}-${env}"

    kubectl create secret generic "${APP_NAME}-db" \
        --namespace "$namespace" \
        --from-literal=host="postgresql.storage.svc.cluster.local" \
        --from-literal=port="5432" \
        --from-literal=database="$db_name" \
        --from-literal=username="$db_name" \
        --from-literal=password="$password" \
        --from-literal=url="jdbc:postgresql://postgresql.storage.svc.cluster.local:5432/${db_name}" \
        --from-literal=r2dbc-url="r2dbc:postgresql://postgresql.storage.svc.cluster.local:5432/${db_name}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# Create namespaces
# =============================================================================
create_namespaces() {
    echo -e "${YELLOW}>>> Creating namespaces...${NC}"
    
    for env in "${TARGET_ENVS[@]}"; do
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
# Create database (separate DB per environment)
# =============================================================================
create_database() {
    if [[ "$SKIP_DATABASE" == "true" ]]; then
        echo -e "${YELLOW}>>> Skipping database creation${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}>>> Creating PostgreSQL databases for ${APP_NAME}...${NC}"
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
        -n storage --timeout=120s
    
    # Create or resume a database without rotating existing user passwords.
    for env in "${TARGET_ENVS[@]}"; do
        local db_name="${APP_NAME}-${env}"
        local db_user="${APP_NAME}-${env}"
        local ns="${APP_NAME}-${env}"
        local role_exists
        local db_exists
        local secret_exists="false"
        local secret_password=""
        local saved_password=""
        local db_password=""
        local auth_database="$db_name"
        
        role_exists=$(kubectl exec -n storage postgresql-0 -- env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
            psql -v ON_ERROR_STOP=1 -U postgres -Atqc "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user}')")
        db_exists=$(kubectl exec -n storage postgresql-0 -- env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
            psql -v ON_ERROR_STOP=1 -U postgres -Atqc "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db_name}')")
        saved_password=$(read_saved_database_password "$env")

        if kubectl get secret "${APP_NAME}-db" -n "$ns" >/dev/null 2>&1; then
            secret_exists="true"
            secret_password=$(database_secret_password "$ns")
            if [[ -z "$secret_password" ]]; then
                echo -e "${RED}Error: ${APP_NAME}-db exists in ${ns} without a password key; refusing to change the database user${NC}"
                return 1
            fi
        fi

        if [[ -n "$secret_password" ]]; then
            db_password="$secret_password"
        elif [[ -n "$saved_password" ]]; then
            db_password="$saved_password"
        fi

        if [[ "$role_exists" == "t" ]]; then
            if [[ -z "$db_password" ]]; then
                echo -e "${RED}Error: database user ${db_user} already exists but its password is unavailable; refusing to rotate it${NC}"
                return 1
            fi

            if [[ "$db_exists" != "t" ]]; then
                auth_database="postgres"
            fi

            if ! verify_database_password "$env" "$db_password" "$auth_database"; then
                echo -e "${RED}Error: stored credentials for ${db_user} do not authenticate; refusing to rotate them${NC}"
                return 1
            fi
        elif [[ "$db_exists" == "t" && -z "$db_password" ]]; then
            echo -e "${RED}Error: database ${db_name} exists without a known user password; refusing to alter existing state${NC}"
            return 1
        elif [[ -z "$db_password" ]]; then
            db_password=$(generate_password 32)
            save_database_password "$env" "$db_password"
        fi

        echo -e "${YELLOW}>>> Ensuring database '${db_name}'...${NC}"

        if [[ "$role_exists" != "t" ]]; then
            kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
                psql -v ON_ERROR_STOP=1 -U postgres -v "db_password=$db_password" <<EOSQL
CREATE USER "${db_user}" WITH PASSWORD :'db_password';
EOSQL
        fi

        kubectl exec -i -n storage postgresql-0 -- env PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
            psql -v ON_ERROR_STOP=1 -U postgres <<EOSQL
SELECT 'CREATE DATABASE "${db_name}" OWNER "${db_user}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db_name}')\gexec

GRANT ALL PRIVILEGES ON DATABASE "${db_name}" TO "${db_user}";
EOSQL

        echo -e "${GREEN}✓ Database '${db_name}' is ready; no existing password was changed${NC}"

        if [[ "$secret_exists" != "true" ]]; then
            create_database_secret "$env" "$db_password"
            echo -e "${GREEN}✓ Database secret created in ${ns}${NC}"
        else
            echo -e "${GREEN}✓ Database secret in ${ns} is unchanged${NC}"
        fi

        save_database_password "$env" "$db_password"
    done
    
    echo -e "${GREEN}✓ Passwords saved to $APP_SECRETS_FILE${NC}"
    echo -e "${YELLOW}⚠ Seal the PostgreSQL password in your app repo (enter it at the hidden prompt):${NC}"
    for env in "${TARGET_ENVS[@]}"; do
        echo -e "${YELLOW}  ./scripts/seal-secrets.sh postgresql ${APP_NAME}-${env} --cert <cert-path>${NC}"
    done
}

# =============================================================================
# Create GHCR pull secret (copied from ArgoCD namespace)
# =============================================================================
create_ghcr_secret() {
    echo -e "${YELLOW}>>> Creating GHCR pull secrets...${NC}"
    
    # Check if github-repo-creds exists in argocd namespace
    local ghcr_password
    ghcr_password=$(kubectl get secret github-repo-creds -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    
    if [[ -z "$ghcr_password" ]]; then
        echo -e "${YELLOW}⚠ GitHub credentials not found in ArgoCD namespace${NC}"
        echo -e "${YELLOW}  Run: sudo ./vps/scripts/export-secrets.sh set-scm-credentials github${NC}"
        echo -e "${YELLOW}  Skipping GHCR secret creation...${NC}"
        return 0
    fi
    
    for env in "${TARGET_ENVS[@]}"; do
        local ns="${APP_NAME}-${env}"
        
        # Create docker-registry secret for GHCR
        kubectl create secret docker-registry ghcr-secret \
            --namespace "$ns" \
            --docker-server=ghcr.io \
            --docker-username=git \
            --docker-password="$ghcr_password" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        echo -e "${GREEN}✓ GHCR secret created in ${ns}${NC}"
    done
}

# =============================================================================
# Create CI/CD access
# =============================================================================
create_cicd_access() {
    echo -e "${YELLOW}>>> Creating CI/CD ServiceAccounts...${NC}"
    
    for env in "${TARGET_ENVS[@]}"; do
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
    
    for env in "${TARGET_ENVS[@]}"; do
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
# Create ArgoCD repository secret for private repo access
# This allows ArgoCD to clone the app repository
# =============================================================================
create_argocd_repo_secret() {
    echo -e "${YELLOW}>>> Creating ArgoCD repository secret for ${APP_NAME}...${NC}"
    
    # Check if github-repo-creds exists (contains the token)
    local token
    token=$(kubectl get secret github-repo-creds -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    
    if [[ -z "$token" ]]; then
        # Try scm-token as fallback
        token=$(kubectl get secret scm-token -n argocd -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    fi
    
    if [[ -z "$token" ]]; then
        echo -e "${YELLOW}⚠ No SCM token found. ArgoCD may not be able to access private repos.${NC}"
        echo -e "${YELLOW}  Run: sudo ./vps/scripts/export-secrets.sh set-scm-credentials github${NC}"
        return 0
    fi
    
    # Determine SCM provider and org from config
    local scm_provider="${SCM_PROVIDER:-github}"
    local scm_org="${SCM_ORGANIZATION:-}"
    
    if [[ -z "$scm_org" ]]; then
        echo -e "${YELLOW}⚠ SCM_ORGANIZATION not set in config.env, skipping repo secret${NC}"
        return 0
    fi
    
    # Build repo URL
    local repo_url
    if [[ "$scm_provider" == "github" ]]; then
        repo_url="https://github.com/${scm_org}/${APP_NAME}.git"
    else
        repo_url="https://gitlab.com/${scm_org}/${APP_NAME}.git"
    fi
    
    local secret_name="repo-${APP_NAME}"
    
    # Check if secret already exists
    if kubectl get secret "$secret_name" -n argocd &>/dev/null; then
        echo -e "${GREEN}✓ Repository secret ${secret_name} already exists${NC}"
        return 0
    fi
    
    # Create repository secret
    kubectl create secret generic "$secret_name" -n argocd \
        --from-literal=type=git \
        --from-literal=url="$repo_url" \
        --from-literal=username=git \
        --from-literal=password="$token"
    
    # Label it for ArgoCD to recognize
    kubectl label secret "$secret_name" -n argocd \
        argocd.argoproj.io/secret-type=repository
    
    echo -e "${GREEN}✓ Repository secret created: ${secret_name}${NC}"
    echo -e "${YELLOW}  ArgoCD can now access: ${repo_url}${NC}"
}

# =============================================================================
# Setup Gateway TLS (certificates + HTTPS listeners)
# =============================================================================
setup_gateway_tls() {
    if [[ "$SKIP_GATEWAY" == "true" ]]; then
        echo -e "${YELLOW}>>> Skipping Gateway TLS setup${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}>>> Setting up Gateway TLS for ${APP_NAME}...${NC}"
    
    local domain_slug
    domain_slug=$(echo "$DOMAIN" | tr '.' '-')
    
    # Create certificates and listeners for each environment
    for env in "${TARGET_ENVS[@]}"; do
        local subdomain
        if [[ "$env" == "alpha" ]]; then
            subdomain="$SUBDOMAIN_ALPHA"
        else
            subdomain="$SUBDOMAIN_PROD"
        fi
        
        local hostname="${subdomain}.${DOMAIN}"
        local cert_name="tls-${subdomain}-${domain_slug}"
        local listener_name="https-${subdomain}"
        
        echo -e "${YELLOW}>>> Creating certificate for ${hostname}...${NC}"
        
        # Check if certificate already exists
        if kubectl get certificate "$cert_name" -n nginx-gateway &>/dev/null; then
            echo -e "${GREEN}✓ Certificate ${cert_name} already exists${NC}"
        else
            # Create certificate
            cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
    name: ${cert_name}
    namespace: nginx-gateway
    labels:
        app.kubernetes.io/managed-by: k3s-stack
        app.kubernetes.io/app: ${APP_NAME}
spec:
    secretName: ${cert_name}
    issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer
    dnsNames:
        - "${hostname}"
EOF
            echo -e "${GREEN}✓ Certificate created for ${hostname}${NC}"
            # Wait for certificate to be ready
            echo -e "${YELLOW}Waiting for certificate (max 120s)...${NC}"
            local timeout=120
            local elapsed=0
            while [[ $elapsed -lt $timeout ]]; do
                local ready
                ready=$(kubectl get certificate "$cert_name" -n nginx-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                if [[ "$ready" == "True" ]]; then
                    echo -e "${GREEN}✓ Certificate issued${NC}"
                    break
                fi
                sleep 5
                elapsed=$((elapsed + 5))
            done
        fi
        
        # Check if listener already exists
        local existing_listener
        existing_listener=$(kubectl get gateway infrastructure-gateway -n nginx-gateway -o jsonpath="{.spec.listeners[?(@.name=='${listener_name}')].name}" 2>/dev/null || true)
        
        if [[ -n "$existing_listener" ]]; then
            echo -e "${GREEN}✓ Listener ${listener_name} already exists${NC}"
        else
            echo -e "${YELLOW}>>> Adding HTTPS listener for ${hostname}...${NC}"
            
            # Add HTTPS listener to Gateway
            kubectl patch gateway infrastructure-gateway -n nginx-gateway --type='json' -p="[
              {
                \"op\": \"add\",
                \"path\": \"/spec/listeners/-\",
                \"value\": {
                  \"name\": \"${listener_name}\",
                  \"port\": 443,
                  \"protocol\": \"HTTPS\",
                  \"hostname\": \"${hostname}\",
                  \"tls\": {
                    \"mode\": \"Terminate\",
                    \"certificateRefs\": [{\"kind\": \"Secret\", \"name\": \"${cert_name}\"}]
                  },
                  \"allowedRoutes\": {\"namespaces\": {\"from\": \"All\"}}
                }
              }
            ]"
            
            echo -e "${GREEN}✓ Listener added for ${hostname}${NC}"
        fi
    done
    
    echo -e "${GREEN}✓ Gateway TLS setup complete${NC}"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         ${APP_NAME} Onboarded!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Environment(s):${NC} ${TARGET_ENVS[*]}"
    for env in "${TARGET_ENVS[@]}"; do
        echo -e "  • Namespace: ${APP_NAME}-${env}"
        echo -e "  • Database: ${APP_NAME}-${env}"
    done
    
    if [[ "$SKIP_GATEWAY" != "true" && -n "${DOMAIN:-}" ]]; then
        echo -e "\n${YELLOW}Gateway TLS:${NC}"
        for env in "${TARGET_ENVS[@]}"; do
            local subdomain="$SUBDOMAIN_ALPHA"
            if [[ "$env" == "prod" ]]; then
                subdomain="$SUBDOMAIN_PROD"
            fi
            echo -e "  • https://${subdomain}.${DOMAIN} → ${APP_NAME}-${env}"
        done
    fi
    
    echo -e "\n${YELLOW}Secrets in selected namespace(s):${NC}"
    echo -e "  • ${APP_NAME}-db → database password and connection metadata"
    echo -e "  • ghcr-secret    → Docker registry credentials for GHCR"
    if [[ "$SKIP_CICD" != "true" ]]; then
        echo -e "\n${YELLOW}CI/CD Kubeconfigs (secured in /root/):${NC}"
        for env in "${TARGET_ENVS[@]}"; do
            echo -e "  • Export: sudo ./vps/scripts/export-secrets.sh export-kubeconfig ${APP_NAME} ${env} /tmp/kc.yaml"
        done
        echo -e "${YELLOW}Use these kubeconfigs only if deploying outside ArgoCD.${NC}"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         Onboarding: ${APP_NAME} (${TARGET_ENVS[*]})${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    umask 077
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    APP_SECRETS_FILE="${SECRETS_DIR}/${APP_NAME}.env"
    touch "$APP_SECRETS_FILE"
    chmod 600 "$APP_SECRETS_FILE"  # Only root can read
    
    load_config
    load_secrets
    create_namespaces
    create_database
    create_ghcr_secret
    create_argocd_repo_secret  # Allow ArgoCD to clone private repo
    if [[ "$SKIP_CICD" != "true" ]]; then
        create_cicd_access
    else
        echo -e "${YELLOW}>>> Skipping CI/CD access setup${NC}"
    fi
    setup_gateway_tls
    print_summary
}

main