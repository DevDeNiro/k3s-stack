# =============================================================================
# Argo CD ApplicationSet - Auto-Discovery
# Automatically discovers and deploys applications from SCM repositories
# =============================================================================
#
# Generated from template. Do not edit directly.
# Edit vps/config.env and run: ./vps/scripts/apply-config.sh
#
# Prerequisites:
#   1. Configure SCM token: sudo ./vps/scripts/export-secrets.sh set-github-token
#   2. Generate manifests: ./vps/scripts/apply-config.sh
#   3. Apply: kubectl apply -f vps/manifests/argocd-autodiscover.yaml
#
# Note: The scm-token Secret is managed separately via export-secrets.sh.
#       Do NOT include it here to avoid overwriting with empty values.
#
# Image Updater: v1.1.0+ uses CRDs (ImageUpdater kind), not annotations.
#       Annotations below are read by the ImageUpdater CR (useAnnotations: true).
#       See argocd-image-updater-crs.yaml for the CRs.
#
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
                # Force usage of immutable SHA tags (avoids "stuck" deployments with mutable 'develop' tag)
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^([a-f0-9]{7,40}|sha-[a-f0-9]{7,40})$"
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
                # Prod: Allow SemVer (v1.0.0) AND immutable SHA (continuous deployment), but BAN 'latest'
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^(v?[0-9]+\\.[0-9]+\\.[0-9]+.*|sha-[a-f0-9]{7,40})$"
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
                            value: latest
            destination:
                server: https://kubernetes.default.svc
                namespace: "{{repository}}-prod"
            syncPolicy:
                syncOptions:
                    - CreateNamespace=true
