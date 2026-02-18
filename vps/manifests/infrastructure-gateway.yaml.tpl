# =============================================================================
# Infrastructure Gateway
# Main entry point for all HTTP/HTTPS traffic in the cluster
#
# This Gateway is managed by k3s-stack platform and shared by all applications.
# Applications attach their HTTPRoutes to this Gateway via parentRefs.
#
# TLS Strategy: Per-hostname certificates (not wildcard) for HTTP-01 compatibility
# Certificates are created separately via cert-manager Certificate resources.
#
# Generated from template. Do not edit directly.
# Edit vps/config.env and run: ./vps/scripts/apply-config.sh
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
spec:
    gatewayClassName: nginx
    listeners:
        # =================================================================
        # HTTP Listeners (port 80)
        # Used for: HTTP-01 ACME challenges, HTTP to HTTPS redirects
        # =================================================================
        - name: http-wildcard
          port: 80
          protocol: HTTP
          hostname: "*.{{DOMAIN}}"
          allowedRoutes:
              namespaces:
                  from: All
        
        - name: http-apex
          port: 80
          protocol: HTTP
          hostname: "{{DOMAIN}}"
          allowedRoutes:
              namespaces:
                  from: All
        
        # =================================================================
        # HTTPS Listeners (port 443)
        # Each hostname needs its own listener with its certificate
        # Add more listeners as you onboard applications
        # =================================================================
        
        # Auth service (Keycloak)
        - name: https-auth
          port: 443
          protocol: HTTPS
          hostname: "auth.{{DOMAIN}}"
          tls:
              mode: Terminate
              certificateRefs:
                  - kind: Secret
                    name: tls-auth-{{DOMAIN_SLUG}}
          allowedRoutes:
              namespaces:
                  from: All
