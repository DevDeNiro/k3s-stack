# =============================================================================
# Infrastructure Gateway
# Main entry point for all HTTP/HTTPS traffic in the cluster
#
# This Gateway is managed by k3s-stack platform and shared by all applications.
# Applications attach their HTTPRoutes to this Gateway via parentRefs.
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
    annotations:
        # cert-manager will automatically create Certificate resources
        # for each listener with TLS configuration
        cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
    gatewayClassName: nginx
    listeners:
        # HTTP listener - redirects to HTTPS or serves HTTP-01 challenges
        - name: http
          port: 80
          protocol: HTTP
          hostname: "*.{{DOMAIN}}"
          allowedRoutes:
              namespaces:
                  from: All
        
        # HTTPS listener - main TLS termination point
        - name: https
          port: 443
          protocol: HTTPS
          hostname: "*.{{DOMAIN}}"
          tls:
              mode: Terminate
              certificateRefs:
                  - kind: Secret
                    name: wildcard-tls-{{DOMAIN_SLUG}}
          allowedRoutes:
              namespaces:
                  from: All

---
# ReferenceGrant to allow HTTPRoutes from other namespaces to reference this Gateway
# This is required for cross-namespace routing
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
    name: allow-all-httproutes
    namespace: nginx-gateway
    labels:
        app.kubernetes.io/name: infrastructure-gateway
        app.kubernetes.io/component: gateway
        app.kubernetes.io/managed-by: k3s-vps
spec:
    from:
        # Allow HTTPRoutes from any namespace
        - group: gateway.networking.k8s.io
          kind: HTTPRoute
          namespace: "*"
    to:
        # To reference the Gateway
        - group: gateway.networking.k8s.io
          kind: Gateway
          name: infrastructure-gateway
