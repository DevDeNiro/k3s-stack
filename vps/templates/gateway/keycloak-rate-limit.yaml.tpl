# =============================================================================
# Rate limit per client address on the Keycloak OIDC endpoints (HTTPRoute
# keycloak: /realms), NGINX Gateway Fabric RateLimitPolicy (NGINX limit_req)
# Rendered and applied by vps/scripts/setup-gateway-api.sh (and local/install.sh)
# from KEYCLOAK_RATE_LIMIT_RATE and KEYCLOAK_RATE_LIMIT_BURST (config.env).
#
# Requests above the rate are served at once up to the burst (noDelay), then
# answered 429 until the rate frees room. A login page costs one or two requests
# here: its assets go through the HTTPRoute keycloak-resources, not limited.
# The hostPorts of the data plane keep the client address ($binary_remote_addr).
# Keycloak brute force detection (realm setting) protects the accounts behind it.
# =============================================================================
---
apiVersion: gateway.nginx.org/v1alpha1
kind: RateLimitPolicy
metadata:
  name: keycloak
  namespace: security
  labels:
    app.kubernetes.io/name: keycloak
    app.kubernetes.io/managed-by: k3s-stack
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: keycloak
  rateLimit:
    rejectCode: 429
    logLevel: warn
    local:
      rules:
        - key: "$binary_remote_addr"
          # About 16 000 client addresses per megabyte
          zoneSize: 1m
          rate: "${RATE}"
          burst: ${BURST}
          noDelay: true
