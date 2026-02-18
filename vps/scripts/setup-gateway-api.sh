#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s VPS Gateway API Setup
# Configures Gateway resources for infrastructure services with TLS
# Uses NGINX Gateway Fabric as the Gateway API implementation
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Set KUBECONFIG for k3s (required for kubectl and Helm)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$(dirname "$SCRIPT_DIR")"

# Default values
DOMAIN=""
ENABLE_TLS=true
LETSENCRYPT_EMAIL=""
INSTALL_CERT_MANAGER=false

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
    echo "  --no-tls                Disable TLS (not recommended)"
    echo "  --cert-manager          Install cert-manager if not present"
    echo "  --email <email>         Email for Let's Encrypt notifications"
    echo "  --help                  Show this help"
    echo ""
    echo "Examples:"
    echo "  # Setup with TLS (cert-manager should already be installed)"
    echo "  $0 --domain example.com"
    echo ""
    echo "  # Setup with TLS and install cert-manager"
    echo "  $0 --domain example.com --cert-manager --email admin@example.com"
    echo ""
    echo "Services configured:"
    echo "  - auth.<domain>        → Keycloak (OAuth/OIDC endpoints only)"
    echo ""
    echo "Prerequisites:"
    echo "  - NGINX Gateway Fabric installed (via install.sh with INSTALL_GATEWAY_API=true)"
    echo "  - cert-manager installed (via setup-cert-manager.sh or --cert-manager flag)"
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
            --no-tls)
                ENABLE_TLS=false
                shift
                ;;
            --cert-manager)
                INSTALL_CERT_MANAGER=true
                shift
                ;;
            --email)
                LETSENCRYPT_EMAIL="$2"
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
}

# -----------------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
    echo -e "\n${YELLOW}>>> Checking prerequisites...${NC}"
    
    # Check if NGINX Gateway Fabric is installed
    if ! kubectl get gatewayclass nginx &>/dev/null; then
        echo -e "${RED}Error: GatewayClass 'nginx' not found.${NC}"
        echo -e "${YELLOW}Make sure NGINX Gateway Fabric is installed via:${NC}"
        echo -e "  ${BLUE}INSTALL_GATEWAY_API=true ./vps/install.sh${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ GatewayClass 'nginx' found${NC}"
    
    # Check if cert-manager is installed (if TLS enabled)
    if [[ "$ENABLE_TLS" == true && "$INSTALL_CERT_MANAGER" == false ]]; then
        if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
            echo -e "${YELLOW}⚠ ClusterIssuer 'letsencrypt-prod' not found.${NC}"
            echo -e "${YELLOW}Installing cert-manager...${NC}"
            INSTALL_CERT_MANAGER=true
            
            # Try to get email from existing config if not provided
            if [[ -z "$LETSENCRYPT_EMAIL" && -f "$VPS_DIR/config.env" ]]; then
                source "$VPS_DIR/config.env"
                LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@$DOMAIN}"
            fi
        else
            echo -e "${GREEN}✓ ClusterIssuer 'letsencrypt-prod' found${NC}"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Install cert-manager
# -----------------------------------------------------------------------------
install_cert_manager() {
    if [[ "$INSTALL_CERT_MANAGER" != true ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Installing cert-manager...${NC}"
    
    # Update config.env with email if needed
    if [[ -n "$LETSENCRYPT_EMAIL" && -f "$VPS_DIR/config.env" ]]; then
        if ! grep -q "LETSENCRYPT_EMAIL" "$VPS_DIR/config.env"; then
            echo "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL" >> "$VPS_DIR/config.env"
        fi
    fi
    
    # Run cert-manager setup script
    if [[ -f "$SCRIPT_DIR/setup-cert-manager.sh" ]]; then
        bash "$SCRIPT_DIR/setup-cert-manager.sh"
    else
        echo -e "${RED}Error: setup-cert-manager.sh not found${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Create infrastructure Gateway
# -----------------------------------------------------------------------------
create_infrastructure_gateway() {
    echo -e "\n${YELLOW}>>> Creating infrastructure Gateway...${NC}"
    
    # Generate domain slug for secret name (replace dots with dashes)
    local domain_slug
    domain_slug=$(echo "$DOMAIN" | tr '.' '-')
    
    # Check if template exists
    local template_file="$VPS_DIR/manifests/infrastructure-gateway.yaml.tpl"
    local output_file="$VPS_DIR/manifests/infrastructure-gateway.yaml"
    
    if [[ -f "$template_file" ]]; then
        # Generate from template
        sed -e "s/{{DOMAIN}}/$DOMAIN/g" \
            -e "s/{{DOMAIN_SLUG}}/$domain_slug/g" \
            "$template_file" > "$output_file"
        echo -e "${GREEN}✓ Generated infrastructure-gateway.yaml from template${NC}"
    else
        # Create directly if no template
        cat > "$output_file" <<EOF
# =============================================================================
# Infrastructure Gateway
# Generated by setup-gateway-api.sh
# =============================================================================

---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
    name: infrastructure-gateway
    namespace: nginx-gateway
    labels:
        app.kubernetes.io/name: infrastructure-gateway
        app.kubernetes.io/component: gateway
        app.kubernetes.io/managed-by: k3s-vps
    annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
    gatewayClassName: nginx
    listeners:
        - name: http
          port: 80
          protocol: HTTP
          hostname: "*.$DOMAIN"
          allowedRoutes:
              namespaces:
                  from: All
EOF

        if [[ "$ENABLE_TLS" == true ]]; then
            cat >> "$output_file" <<EOF
        - name: https
          port: 443
          protocol: HTTPS
          hostname: "*.$DOMAIN"
          tls:
              mode: Terminate
              certificateRefs:
                  - kind: Secret
                    name: wildcard-tls-$domain_slug
          allowedRoutes:
              namespaces:
                  from: All
EOF
        fi
    fi
    
    # Apply the Gateway
    kubectl apply -f "$output_file"
    
    echo -e "${GREEN}✓ Infrastructure Gateway created${NC}"
}

# -----------------------------------------------------------------------------
# Create HTTPRoute for Keycloak
# -----------------------------------------------------------------------------
create_keycloak_httproute() {
    echo -e "\n${YELLOW}>>> Creating HTTPRoute for Keycloak...${NC}"
    
    local host="auth.${DOMAIN}"
    
    # Check if Keycloak service exists
    if ! kubectl get svc keycloak -n security &>/dev/null; then
        echo -e "${YELLOW}⚠ Keycloak service not found in 'security' namespace - skipping HTTPRoute${NC}"
        return 0
    fi
    
    # Build HTTPRoute for Keycloak
    # Only expose /realms/* and /resources/* (NOT /admin/*)
    cat <<EOF | kubectl apply -f -
# =============================================================================
# HTTPRoute for Keycloak - OAuth/OIDC endpoints only
# /admin/* is NOT exposed - use port-forward for admin access
# =============================================================================
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: keycloak
    namespace: security
    labels:
        app.kubernetes.io/name: keycloak
        app.kubernetes.io/component: auth
        app.kubernetes.io/managed-by: k3s-vps
spec:
    parentRefs:
        - name: infrastructure-gateway
          namespace: nginx-gateway
    hostnames:
        - "${host}"
    rules:
        # OIDC/OAuth2 endpoints (required for authentication)
        - matches:
            - path:
                type: PathPrefix
                value: /realms
          backendRefs:
            - name: keycloak
              port: 80
        # Static resources (login page assets)
        - matches:
            - path:
                type: PathPrefix
                value: /resources
          backendRefs:
            - name: keycloak
              port: 80
        # Robots.txt
        - matches:
            - path:
                type: Exact
                value: /robots.txt
          backendRefs:
            - name: keycloak
              port: 80
EOF
    
    echo -e "${GREEN}✓ Keycloak HTTPRoute created${NC}"
    echo -e "  ${GREEN}Public:${NC}  /realms/*, /resources/*"
    echo -e "  ${RED}Blocked:${NC} /admin/* (use port-forward)"
}

# -----------------------------------------------------------------------------
# Create HTTP to HTTPS redirect
# -----------------------------------------------------------------------------
create_https_redirect() {
    if [[ "$ENABLE_TLS" != true ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Creating HTTP to HTTPS redirect...${NC}"
    
    cat <<EOF | kubectl apply -f -
# =============================================================================
# HTTPRoute for HTTP to HTTPS redirect
# Redirects all HTTP traffic to HTTPS
# =============================================================================
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: https-redirect
    namespace: nginx-gateway
    labels:
        app.kubernetes.io/name: https-redirect
        app.kubernetes.io/component: gateway
        app.kubernetes.io/managed-by: k3s-vps
spec:
    parentRefs:
        - name: infrastructure-gateway
          namespace: nginx-gateway
          sectionName: http-wildcard
    hostnames:
        - "*.${DOMAIN}"
    rules:
        - filters:
            - type: RequestRedirect
              requestRedirect:
                  scheme: https
                  statusCode: 301
EOF
    
    echo -e "${GREEN}✓ HTTPS redirect HTTPRoute created${NC}"
}

# -----------------------------------------------------------------------------
# Create TLS Certificates (HTTP-01 challenge - per hostname, not wildcard)
# -----------------------------------------------------------------------------
create_certificates() {
    if [[ "$ENABLE_TLS" != true ]]; then
        return 0
    fi
    
    echo -e "\n${YELLOW}>>> Creating TLS certificates (HTTP-01)...${NC}"
    
    local domain_slug
    domain_slug=$(echo "$DOMAIN" | tr '.' '-')
    
    # Certificate for auth.domain (Keycloak)
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
    name: tls-auth-${domain_slug}
    namespace: nginx-gateway
    labels:
        app.kubernetes.io/managed-by: k3s-vps
spec:
    secretName: tls-auth-${domain_slug}
    issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer
    dnsNames:
        - "auth.${DOMAIN}"
EOF
    
    echo -e "${GREEN}✓ Certificate created for auth.${DOMAIN}${NC}"
    
    # Wait for certificate to be ready (with timeout)
    echo -e "${YELLOW}Waiting for certificate to be issued (this may take 1-2 minutes)...${NC}"
    local timeout=120
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(kubectl get certificate tls-auth-${domain_slug} -n nginx-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$ready" == "True" ]]; then
            echo -e "${GREEN}✓ Certificate issued successfully${NC}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -ne "\r  Waiting... ${elapsed}s / ${timeout}s"
    done
    
    echo -e "\n${YELLOW}⚠ Certificate not ready yet. Check status with:${NC}"
    echo -e "  ${BLUE}kubectl get certificates -A${NC}"
    echo -e "  ${BLUE}kubectl describe certificate tls-auth-${domain_slug} -n nginx-gateway${NC}"
    echo -e "  ${BLUE}kubectl get challenges -A${NC}"
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
    echo -e "${GREEN}         Gateway API Setup Complete!                          ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Gateway Configuration:${NC}"
    echo -e "  Name: infrastructure-gateway"
    echo -e "  Namespace: nginx-gateway"
    echo -e "  Domain: *.${DOMAIN}"
    
    if [[ "$ENABLE_TLS" == true ]]; then
        echo -e "  TLS: ${GREEN}Enabled${NC} (cert-manager with Let's Encrypt)"
    else
        echo -e "  TLS: ${RED}Disabled${NC}"
    fi
    
    echo -e "\n${YELLOW}Public Service URLs:${NC}"
    echo -e "  Keycloak (OAuth): ${protocol}://auth.${DOMAIN}/realms/*"
    echo -e "  ${RED}Keycloak Admin:    BLOCKED (use port-forward)${NC}"
    
    echo -e "\n${YELLOW}Private Services (port-forward only):${NC}"
    echo -e "  ${BLUE}Grafana:    kubectl port-forward -n monitoring svc/grafana 3000:80${NC}"
    echo -e "  ${BLUE}Prometheus: kubectl port-forward -n monitoring svc/prometheus-server 9090:80${NC}"
    echo -e "  ${BLUE}Keycloak Admin: kubectl port-forward -n security svc/keycloak 8080:80${NC}"
    
    echo -e "\n${YELLOW}DNS Configuration:${NC}"
    echo -e "  Add the following DNS record pointing to your VPS IP:"
    echo -e "  ${BLUE}*.${DOMAIN}        A    <VPS-IP>${NC}"
    echo -e "  Or individually:"
    echo -e "  ${BLUE}auth.${DOMAIN}     A    <VPS-IP>${NC}"
    
    if [[ "$ENABLE_TLS" == true ]]; then
        echo -e "\n${YELLOW}TLS Status:${NC}"
        echo -e "  ${GREEN}✓ Using cert-manager with Let's Encrypt${NC}"
        echo -e "  Certificates will be automatically issued after DNS is configured."
        echo -e "\n  Check certificate status:"
        echo -e "  ${BLUE}kubectl get certificates -A${NC}"
        echo -e "  ${BLUE}kubectl describe gateway infrastructure-gateway -n nginx-gateway${NC}"
    fi
    
    echo -e "\n${YELLOW}Verify Gateway:${NC}"
    echo -e "  ${BLUE}kubectl get gateways -n nginx-gateway${NC}"
    echo -e "  ${BLUE}kubectl get httproutes -A${NC}"
    
    echo -e "\n${YELLOW}For your applications:${NC}"
    echo -e "  Create an HTTPRoute in your app namespace referencing the Gateway:"
    echo -e "  ${BLUE}parentRefs:${NC}"
    echo -e "  ${BLUE}  - name: infrastructure-gateway${NC}"
    echo -e "  ${BLUE}    namespace: nginx-gateway${NC}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         K3s VPS Gateway API Setup                             ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Domain: ${DOMAIN}"
    echo -e "TLS: ${ENABLE_TLS}"
    
    check_prerequisites
    install_cert_manager
    create_infrastructure_gateway  # Gateway first (HTTP listeners needed for HTTP-01 challenge)
    create_certificates            # Create TLS certificates AFTER Gateway exists
    create_keycloak_httproute
    create_https_redirect
    print_summary
}

main "$@"
