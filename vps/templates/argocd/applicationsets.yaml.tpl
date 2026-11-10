# =============================================================================
# Argo CD ApplicationSets - Auto-Discovery of the GitHub organization repositories
# Rendered and applied by vps/scripts/apply-config.sh
# (variables: SCM_ORGANIZATION, REGISTRY_BASE from config.env).
#
# The scm-token Secret is managed by export-secrets.sh set-scm-credentials,
# never here (it would be overwritten with empty values).
#
# Image Updater v1.1.0+ reads the annotations below through the ImageUpdater
# CRs of manifests/argocd-image-updaters.yaml (useAnnotations: true).
# =============================================================================

---
# ApplicationSet - Alpha environments (develop branch)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
    name: autodiscover-alpha
    namespace: argocd
spec:
    generators:
        -   scmProvider:
                github:
                    organization: ${SCM_ORGANIZATION}
                    tokenRef:
                        secretName: scm-token
                        key: token
                    allBranches: false
                cloneProtocol: https
                # IMPORTANT: SCM provider does NOT support glob patterns in pathsExist
                # Use 'helm' directory check, the helm chart path is derived from repo name
                filters:
                    -   pathsExist:
                            - helm

    # Allow Image Updater to modify helm parameters without being reverted
    ignoreApplicationDifferences:
        -   jsonPointers:
                - /spec/source/helm/parameters

    template:
        metadata:
            name: "{{repository}}-alpha"
            namespace: argocd
            labels:
                app.kubernetes.io/name: "{{repository}}"
                app.kubernetes.io/environment: alpha
                app.kubernetes.io/managed-by: argocd-autodiscover
            annotations:
                argocd-image-updater.argoproj.io/image-list: "app=${REGISTRY_BASE}/{{repository}}"
                argocd-image-updater.argoproj.io/app.update-strategy: newest-build
                # Only deploy immutable builds created from the develop branch (CI tag develop-<full sha>)
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^develop-[a-f0-9]{40}$"
                argocd-image-updater.argoproj.io/write-back-method: argocd
                argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
                argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
        spec:
            project: default
            source:
                repoURL: "{{url}}"
                targetRevision: develop
                path: helm/{{repository}}
                helm:
                    valueFiles:
                        - values.yaml
                        - values-alpha.yaml
                    parameters:
                        -   name: image.repository
                            value: "${REGISTRY_BASE}/{{repository}}"
                        -   name: image.tag
                            value: develop
            destination:
                server: https://kubernetes.default.svc
                namespace: "{{repository}}-alpha"
            syncPolicy:
                automated:
                    prune: true
                    selfHeal: true
                syncOptions:
                    - CreateNamespace=true

---
# ApplicationSet - Production environments (main branch)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
    name: autodiscover-prod
    namespace: argocd
spec:
    generators:
        -   scmProvider:
                github:
                    organization: ${SCM_ORGANIZATION}
                    tokenRef:
                        secretName: scm-token
                        key: token
                    allBranches: false
                cloneProtocol: https
                # IMPORTANT: SCM provider does NOT support glob patterns in pathsExist
                # Use 'helm' directory check, the helm chart path is derived from repo name
                filters:
                    -   pathsExist:
                            - helm

    # Allow Image Updater to modify helm parameters without being reverted
    ignoreApplicationDifferences:
        -   jsonPointers:
                - /spec/source/helm/parameters

    template:
        metadata:
            name: "{{repository}}-prod"
            namespace: argocd
            labels:
                app.kubernetes.io/name: "{{repository}}"
                app.kubernetes.io/environment: prod
                app.kubernetes.io/managed-by: argocd-autodiscover
            annotations:
                argocd-image-updater.argoproj.io/image-list: "app=${REGISTRY_BASE}/{{repository}}"
                argocd-image-updater.argoproj.io/app.update-strategy: newest-build
                # Only deploy immutable builds created from the main branch
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^main-[a-f0-9]{40}$"
                argocd-image-updater.argoproj.io/write-back-method: argocd
                argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
                argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
        spec:
            project: default
            source:
                repoURL: "{{url}}"
                targetRevision: main
                path: helm/{{repository}}
                helm:
                    valueFiles:
                        - values.yaml
                        - values-prod.yaml
                    parameters:
                        -   name: image.repository
                            value: "${REGISTRY_BASE}/{{repository}}"
                        -   name: image.tag
                            value: main
            destination:
                server: https://kubernetes.default.svc
                namespace: "{{repository}}-prod"
            syncPolicy:
                # Auto-sync prod désactivé tant que les secrets prod (coterie-webapp-secrets) ne sont pas prêts
                syncOptions:
                    - CreateNamespace=true
