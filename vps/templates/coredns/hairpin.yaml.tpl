# =============================================================================
# In-cluster resolution of the public hostnames (hairpin)
# Rendered and applied by vps/scripts/setup-gateway-api.sh.
#
# Pods resolving a hostname of GATEWAY_HOSTNAMES get the gateway Service:
# https://<hostname> works from inside the cluster with the public certificate,
# and the cert-manager HTTP-01 self-check reaches the gateway.
# K3s CoreDNS imports every "*.override" key of the optional ConfigMap
# kube-system/coredns-custom into its main server block.
# =============================================================================
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: k3s-stack
data:
  k3s-stack-hairpin.override: |
${REWRITE_RULES}
