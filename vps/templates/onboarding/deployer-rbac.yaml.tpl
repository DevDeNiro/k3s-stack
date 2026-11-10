# =============================================================================
# Optional CI/CD access (vps/scripts/onboard-app.sh --with-cicd)
# A deployer ServiceAccount limited to its namespace, with a long-lived token.
# Argo CD pulls the deployments: only create this for a pipeline that must
# reach the API (through an SSH tunnel or an --allow-api-from network).
# =============================================================================
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployer
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer-role
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["", "apps", "networking.k8s.io", "batch"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-binding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: deployer
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: deployer-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: deployer-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: deployer
type: kubernetes.io/service-account-token
