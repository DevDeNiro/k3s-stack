# =============================================================================
# Certificate of one public hostname, served by the HTTPS listener https-<slug>
# Rendered and applied by vps/scripts/setup-gateway-api.sh for each hostname of
# GATEWAY_HOSTNAMES; certificates of removed hostnames are pruned (label below).
# =============================================================================
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-${HOST_SLUG}
  namespace: nginx-gateway
  labels:
    app.kubernetes.io/managed-by: k3s-stack
    app.kubernetes.io/component: gateway-certificate
spec:
  secretName: tls-${HOST_SLUG}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - "${HOST}"
