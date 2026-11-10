# =============================================================================
# Keycloak public routes for the hostnames of AUTH_HOSTNAMES
# Rendered and applied by vps/scripts/setup-gateway-api.sh (and local/install.sh).
#
# Only the OIDC endpoints (/realms) and the login assets (/resources) are
# public. The admin console (/admin) is not routed and the master realm
# (administration) gets no backend: both stay private, reachable through
# "kubectl port-forward -n security svc/keycloak 8080:80".
# Two routes: the RateLimitPolicy keycloak (keycloak-rate-limit.yaml.tpl)
# targets the OIDC endpoints only, never the login assets loaded by every page.
# Bound to the HTTPS listeners only: plain HTTP is redirected to HTTPS.
# =============================================================================
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
  namespace: security
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/managed-by: k3s-stack
spec:
  parentRefs:
${PARENT_REFS}
  hostnames:
${HOSTNAMES}
  rules:
    # Master realm: no backendRefs, the gateway answers without reaching Keycloak
    - matches:
        - path:
            type: PathPrefix
            value: /realms/master
    - matches:
        - path:
            type: PathPrefix
            value: /realms
      backendRefs:
        - name: keycloak
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak-resources
  namespace: security
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/managed-by: k3s-stack
spec:
  parentRefs:
${PARENT_REFS}
  hostnames:
${HOSTNAMES}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /resources
      backendRefs:
        - name: keycloak
          port: 80
