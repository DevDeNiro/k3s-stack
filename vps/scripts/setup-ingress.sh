#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s VPS Ingress Setup
# Configures Ingress resources for infrastructure services with optional TLS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Set KUBECONFIG for k3s (required for kubectl and Helm)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
DOMAIN=""
ENABLE_TLS=false
TLS_SECRET_NAME="infrastructure-tls"
INSTALL_CERT_MANAGER=false
USE_CERT_MANAGER=false
LETSENCRYPT_EMAIL=""

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 --domain <domain> [options]"
    echo ""
    echo "Required:"
    echo "  --domain <domain>       Base domain for services (e.g., example.com)"
    echo ""
    echo "Options:"
    echo "  --tls                   Enable TLS (requires cert-manager or manual certs)"
    echo "  --cert-manager          Install cert-manager with Let's Encrypt"
    echo "  --email <email>         Email for Let's Encrypt notifications"
    echo "  --tls-secret <name>     TLS secret name (default: infrastructure-tls)"
    echo "  --help                  Show this help"
    echo ""
    echo "Examples:"
    echo "  # HTTP only"
    echo "  $0 --domain example.com"
    echo ""
    echo "  # HTTPS with Let's Encrypt"
    echo "  $0 --domain example.com --tls --cert-manager --email admin@example.com"
    echo ""
    echo "  # HTTPS with existing certificate"
    echo "  $0 --domain example.com --tls --tls-secret my-tls-secret"
    echo ""
    echo "Services configured:"
    echo "  - grafana.<domain>     → Grafana dashboard"
    echo "  - auth.<domain>        → Keycloak"
    echo "  - prometheus.<domain>  → Prometheus"
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --tls)
                ENABLE_TLS=true
                shift
                ;;
            --cert-manager)
                INSTALL_CERT_MANAGER=true
                ENABLE_TLS=true
                shift
                ;;
            --email)
                LETSENCRYPT_EMAIL="$2"
                shift 2
                ;;
            --tls-secret)
                TLS_SECRET_NAME="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}Error: --domain is required${NC}"
        usage
        exit 1
    fi
    
    if [[ "$INSTALL_CERT_MANAGER" == true && -z "$LETSENCRYPT_EMAIL" ]]; then
        echo -e "${RED}Error: --email is required when using --cert-manager${NC}"
        usage
        exit 1
    fi
    
    # Auto-detect if cert-manager is already installed with ClusterIssuer
    if [[ "$ENABLE_TLS" == true && "$INSTALL_CERT_MANAGER" == false ]]; then
        if kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
            echo -e "${GREEN}✓ Detected existing cert-manager with letsencrypt-prod ClusterIssuer${NC}"
            USE_CERT_MANAGER=true
        fi
    fi
    
    if [[ "$INSTALL_CERT_MANAGER" == true ]]; then
        USE_CERT_MANAGER=true
    fi
}

# -----------------------------------------------------------------------------
# Install cert-manager
# -----------------------------------------------------------------------------
install_cert_manager() {
    echo -e "${YELLOW}>>> Installing cert-manager...${NC}"
    
    # Check if already installed
    if kubectl get namespace cert-manager &>/dev/null; then
        echo -e "${GREEN}✓ cert-manager already installed${NC}"
        return 0
    fi
    
    # Install cert-manager
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    echo -e "${YELLOW}Waiting for cert-manager to be ready...${NC}"
    kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
    kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
    kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
    
    echo -e "${GREEN}✓ cert-manager installed${NC}"
}

# -----------------------------------------------------------------------------
# Create ClusterIssuer for Let's Encrypt
# -----------------------------------------------------------------------------
create_cluster_issuer() {
    echo -e "${YELLOW}>>> Creating Let's Encrypt ClusterIssuer...${NC}"
    
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

    echo -e "${GREEN}✓ ClusterIssuers created${NC}"
}

# -----------------------------------------------------------------------------
# Create Ingress for a service
# -----------------------------------------------------------------------------
create_ingress() {
    local name="$1"
    local namespace="$2"
    local service="$3"
    local port="$4"
    local subdomain="$5"
    local host="${subdomain}.${DOMAIN}"
    
    echo -e "${YELLOW}Creating Ingress for ${name} (${host})...${NC}"
    
    # Check if service exists
    if ! kubectl get svc "$service" -n "$namespace" &>/dev/null; then
        echo -e "${YELLOW}⚠ Service $service not found in $namespace - skipping${NC}"
        return 0
    fi
    
    # Build annotations with rate limiting (brute-force protection)
    # 10 requests/second burst, 5 requests/second sustained
    local annotations="nginx.ingress.kubernetes.io/proxy-body-size: \"50m\"
    nginx.ingress.kubernetes.io/limit-rps: \"10\"
    nginx.ingress.kubernetes.io/limit-connections: \"5\"
    nginx.ingress.kubernetes.io/limit-rpm: \"300\""
    
    if [[ "$ENABLE_TLS" == true && "$USE_CERT_MANAGER" == true ]]; then
        annotations="${annotations}
    cert-manager.io/cluster-issuer: letsencrypt-prod"
    fi
    
    # Keycloak: NO rate limiting - admin UI loads many JS modules dynamically
    # Keycloak has its own brute force protection built-in
    if [[ "$name" == "keycloak" ]]; then
        # Remove default rate limits, add proxy buffering for large responses
        annotations="nginx.ingress.kubernetes.io/proxy-body-size: \"50m\"
    nginx.ingress.kubernetes.io/proxy-buffer-size: \"256k\"
    nginx.ingress.kubernetes.io/proxy-buffers-number: \"8\""
        if [[ "$ENABLE_TLS" == true && "$USE_CERT_MANAGER" == true ]]; then
            annotations="${annotations}
    cert-manager.io/cluster-issuer: letsencrypt-prod"
        fi
    fi
    
    # Add basic auth for Prometheus (no native auth)
    if [[ "$name" == "prometheus" ]]; then
        # Create basic auth secret if not exists
        if ! kubectl get secret prometheus-basic-auth -n monitoring &>/dev/null; then
            echo -e "${YELLOW}Creating basic auth for Prometheus...${NC}"
            # Use same password as Grafana for simplicity
            local grafana_pass
            grafana_pass=$(kubectl get secret grafana-secret -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "admin")
            
            # Generate htpasswd-compatible string (user:password hash)
            # Use htpasswd if available, otherwise use openssl
            local auth_string
            if command -v htpasswd &>/dev/null; then
                auth_string=$(htpasswd -nb admin "$grafana_pass")
            else
                # Fallback: use openssl to generate apr1 hash (Apache MD5)
                local salt
                salt=$(openssl rand -base64 6 | tr -dc 'a-zA-Z0-9' | head -c 8)
                local hash
                hash=$(openssl passwd -apr1 -salt "$salt" "$grafana_pass")
                auth_string="admin:${hash}"
            fi
            
            kubectl create secret generic prometheus-basic-auth -n monitoring \
                --from-literal=auth="$auth_string" --dry-run=client -o yaml | kubectl apply -f -
        fi
        annotations="${annotations}
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: prometheus-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: \"Prometheus - Authentication Required\""
    fi
    
    # Build TLS section
    local tls_section=""
    if [[ "$ENABLE_TLS" == true ]]; then
        tls_section="
  tls:
    - hosts:
        - ${host}
      secretName: ${name}-tls"
    fi
    
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}-ingress
  namespace: ${namespace}
  annotations:
    ${annotations}
spec:
  ingressClassName: nginx
  rules:
    - host: ${host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${service}
                port:
                  number: ${port}${tls_section}
EOF

    echo -e "${GREEN}✓ Ingress ${name}-ingress created${NC}"
}

# -----------------------------------------------------------------------------
# Create Keycloak Ingress (only OAuth/OIDC paths - /admin NOT exposed)
# -----------------------------------------------------------------------------
create_keycloak_ingress() {
    local host="auth.${DOMAIN}"
    
    echo -e "${YELLOW}Creating secure Keycloak Ingress (${host})...${NC}"
    
    # Check if service exists
    if ! kubectl get svc keycloak -n security &>/dev/null; then
        echo -e "${YELLOW}⚠ Service keycloak not found in security - skipping${NC}"
        return 0
    fi
    
    # Build cert-manager annotation if TLS enabled
    local cert_annotation=""
    if [[ "$ENABLE_TLS" == true && "$USE_CERT_MANAGER" == true ]]; then
        cert_annotation="cert-manager.io/cluster-issuer: letsencrypt-prod"
    fi
    
    # Build TLS section
    local tls_section=""
    if [[ "$ENABLE_TLS" == true ]]; then
        tls_section="
  tls:
    - hosts:
        - ${host}
      secretName: keycloak-tls"
    fi
    
    # Strategy: Only expose specific paths needed for OAuth/OIDC
    # This is more secure than blocking /admin with server-snippet
    # (server-snippets are disabled by default in nginx-ingress for security)
    #
    # Exposed paths:
    #   /realms/*     - OIDC endpoints (auth, token, userinfo, certs, etc.)
    #   /resources/*  - Static assets (CSS, JS for login pages)
    #   /robots.txt   - SEO
    #
    # NOT exposed (access via port-forward only):
    #   /admin/*      - Admin console
    #   /metrics      - Prometheus metrics
    #   /health/*     - Health endpoints
    
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-ingress
  namespace: security
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "256k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
    ${cert_annotation}
spec:
  ingressClassName: nginx
  rules:
    - host: ${host}
      http:
        paths:
          # OIDC/OAuth2 endpoints (required for authentication)
          - path: /realms
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 80
          # Static resources (login page assets)
          - path: /resources
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 80
          # Robots.txt
          - path: /robots.txt
            pathType: Exact
            backend:
              service:
                name: keycloak
                port:
                  number: 80${tls_section}
EOF

    echo -e "${GREEN}✓ Keycloak Ingress created${NC}"
    echo -e "  ${GREEN}Public:${NC}  /realms/*, /resources/*"
    echo -e "  ${RED}Blocked:${NC} /admin/* (use port-forward)"
}

# -----------------------------------------------------------------------------
# Create all infrastructure ingresses
# -----------------------------------------------------------------------------
create_all_ingresses() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         Creating Infrastructure Ingresses                      ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    # Keycloak only - Grafana and Prometheus are accessed via port-forward
    create_keycloak_ingress
    
    echo -e "\n${YELLOW}⚠ Grafana and Prometheus are NOT exposed publicly for security.${NC}"
    echo -e "${YELLOW}  Access them via port-forward:${NC}"
    echo -e "${BLUE}    kubectl port-forward -n monitoring svc/grafana 3000:80${NC}"
    echo -e "${BLUE}    kubectl port-forward -n monitoring svc/prometheus-server 9090:80${NC}"
}

# -----------------------------------------------------------------------------
# Print summary
# -----------------------------------------------------------------------------
print_summary() {
    local protocol="http"
    if [[ "$ENABLE_TLS" == true ]]; then
        protocol="https"
    fi
    
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Ingress Setup Complete!                               ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Public Service URLs:${NC}"
    echo -e "  Keycloak (OAuth): ${protocol}://auth.${DOMAIN}/realms/*"
    echo -e "  ${RED}Keycloak Admin:    BLOCKED (use port-forward)${NC}"
    
    echo -e "\n${YELLOW}Private Services (port-forward only):${NC}"
    echo -e "  ${BLUE}Grafana:    kubectl port-forward -n monitoring svc/grafana 3000:80${NC}"
    echo -e "  ${BLUE}Prometheus: kubectl port-forward -n monitoring svc/prometheus-server 9090:80${NC}"
    echo -e "  ${BLUE}Keycloak Admin: kubectl port-forward -n security svc/keycloak 8080:80${NC}"
    
    echo -e "\n${YELLOW}DNS Configuration:${NC}"
    echo -e "  Add the following DNS record pointing to your VPS IP:"
    echo -e "  ${BLUE}auth.${DOMAIN}        A    <VPS-IP>${NC}"
    
    if [[ "$ENABLE_TLS" == true ]]; then
        echo -e "\n${YELLOW}TLS Status:${NC}"
        if [[ "$USE_CERT_MANAGER" == true ]]; then
            echo -e "  ${GREEN}✓ Using cert-manager with Let's Encrypt${NC}"
            echo -e "  Certificates will be automatically issued after DNS is configured."
            echo -e "\n  Check certificate status:"
            echo -e "  ${BLUE}kubectl get certificates -A${NC}"
        else
            echo -e "  Using existing TLS secret: ${TLS_SECRET_NAME}"
        fi
    else
        echo -e "\n${YELLOW}⚠ TLS is disabled. For production, enable TLS with:${NC}"
        echo -e "  ${BLUE}$0 --domain ${DOMAIN} --tls --cert-manager --email your@email.com${NC}"
    fi
    
    echo -e "\n${YELLOW}Verify Ingresses:${NC}"
    echo -e "  ${BLUE}kubectl get ingress -A${NC}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         K3s VPS Ingress Setup                                 ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Domain: ${DOMAIN}"
    echo -e "TLS: ${ENABLE_TLS}"
    
    # Install cert-manager if requested
    if [[ "$INSTALL_CERT_MANAGER" == true ]]; then
        install_cert_manager
        create_cluster_issuer
    fi
    
    # Create ingresses
    create_all_ingresses
    
    # Print summary
    print_summary
}

main "$@"
