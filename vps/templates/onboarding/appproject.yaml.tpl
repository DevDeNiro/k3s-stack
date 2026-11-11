# =============================================================================
# Argo CD AppProject of the application ${APP_NAME} - rendered and applied by
# vps/scripts/onboard-app.sh, once its namespaces, database and Secrets exist.
#
# The ApplicationSets (templates/argocd/applicationsets.yaml.tpl) put the
# Applications ${APP_NAME}-alpha and ${APP_NAME}-prod in this project: a
# repository that is not onboarded has no project, hence no Application.
# The project confines the application to its repository and its namespaces:
#   - destinations: Argo CD checks the namespace of every resource of the
#     chart, not only the destination of the Application
#   - no cluster-scoped resource: namespaces, RBAC, CRDs and webhooks belong to
#     the platform
#   - refused in its namespaces: ResourceQuota and LimitRange (sizing of the
#     onboarding), Endpoints and EndpointSlice (a Service, hence the gateway,
#     would forward to the pods of another namespace)
# =============================================================================
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${APP_NAME}
  namespace: argocd
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: k3s-stack
spec:
  description: "${APP_NAME}: its repository and its namespaces ${APP_NAME}-alpha and ${APP_NAME}-prod"
  sourceRepos:
    - ${REPO_URL}
  destinations:
    - server: https://kubernetes.default.svc
      namespace: ${APP_NAME}-alpha
    - server: https://kubernetes.default.svc
      namespace: ${APP_NAME}-prod
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
    - group: ""
      kind: Endpoints
    - group: discovery.k8s.io
      kind: EndpointSlice
