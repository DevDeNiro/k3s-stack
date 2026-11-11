# =============================================================================
# Shared Gateway - rendered and applied by vps/scripts/setup-gateway-api.sh
#
# Entry point for all HTTP/HTTPS traffic. Applications attach their HTTPRoutes
# with parentRefs: { name: infrastructure-gateway, namespace: nginx-gateway }.
#   - listener "http" (port 80, any hostname): ACME HTTP-01 challenges and the
#     redirection to HTTPS, both routed from nginx-gateway (the Certificates live
#     there): no other namespace attaches to it (Same). With --no-tls (tests),
#     every namespace (All).
#   - one listener "https-<slug>" per hostname of GATEWAY_HOSTNAMES
#     (templates/gateway/https-listener.yaml.tpl, certificate tls-<slug>): only
#     the routes of the namespaces declared for the hostname attach to it
# =============================================================================
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: infrastructure-gateway
  namespace: nginx-gateway
  labels:
    app.kubernetes.io/name: infrastructure-gateway
    app.kubernetes.io/managed-by: k3s-stack
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: ${HTTP_ROUTES_FROM}
${HTTPS_LISTENERS}
