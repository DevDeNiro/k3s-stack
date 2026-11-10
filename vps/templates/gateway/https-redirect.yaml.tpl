# =============================================================================
# HTTP -> HTTPS redirection for every hostname of GATEWAY_HOSTNAMES
# Rendered and applied by vps/scripts/setup-gateway-api.sh (TLS mode).
# The ACME challenge routes created by cert-manager are more specific and keep
# answering on port 80.
# =============================================================================
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: nginx-gateway
  labels:
    app.kubernetes.io/name: https-redirect
    app.kubernetes.io/managed-by: k3s-stack
spec:
  parentRefs:
    - name: infrastructure-gateway
      namespace: nginx-gateway
      sectionName: http
  hostnames:
${HOSTNAMES}
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
