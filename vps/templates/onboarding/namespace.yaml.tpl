# =============================================================================
# Application namespace <app>-<env> - rendered and applied by vps/scripts/onboard-app.sh
# Sizing and Pod Security level: vps/config/onboarding/<env>.env
# The label app.kubernetes.io/managed-by=k3s-stack grants access to PostgreSQL,
# Redis and Keycloak (vps/manifests/network-policies.yaml).
# =============================================================================
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/environment: ${APP_ENV}
    app.kubernetes.io/managed-by: k3s-stack
    pod-security.kubernetes.io/enforce: ${POD_SECURITY_ENFORCE}
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${NAMESPACE}-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "${QUOTA_REQUESTS_CPU}"
    requests.memory: "${QUOTA_REQUESTS_MEMORY}"
    limits.cpu: "${QUOTA_LIMITS_CPU}"
    limits.memory: "${QUOTA_LIMITS_MEMORY}"
    pods: "${QUOTA_PODS}"
---
# Defaults for containers that declare no resources
apiVersion: v1
kind: LimitRange
metadata:
  name: ${NAMESPACE}-limits
  namespace: ${NAMESPACE}
spec:
  limits:
    - type: Container
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
