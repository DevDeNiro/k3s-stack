# =============================================================================
# Cert-Manager ClusterIssuers: Let's Encrypt staging and production
# Rendered and applied by vps/install.sh (variable: LETSENCRYPT_EMAIL from config.env).
# HTTP-01 challenges are solved through the shared Gateway (NGINX Gateway Fabric).
# =============================================================================

---
# Let's Encrypt Staging (for testing)
# Rate limits: very high, but certificates are not trusted by browsers
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
    name: letsencrypt-staging
spec:
    acme:
        server: https://acme-staging-v02.api.letsencrypt.org/directory
        email: ${LETSENCRYPT_EMAIL}
        privateKeySecretRef:
            name: letsencrypt-staging-key
        solvers:
            # Gateway API HTTP-01 solver (NGINX Gateway Fabric)
            -   http01:
                    gatewayHTTPRoute:
                        parentRefs:
                            -   name: infrastructure-gateway
                                namespace: nginx-gateway

---
# Let's Encrypt Production
# Rate limits: 50 certificates/week per domain, use carefully
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
    name: letsencrypt-prod
spec:
    acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: ${LETSENCRYPT_EMAIL}
        privateKeySecretRef:
            name: letsencrypt-prod-key
        solvers:
            # Gateway API HTTP-01 solver (NGINX Gateway Fabric)
            -   http01:
                    gatewayHTTPRoute:
                        parentRefs:
                            -   name: infrastructure-gateway
                                namespace: nginx-gateway
