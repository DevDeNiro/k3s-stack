# =============================================================================
# Argo CD ApplicationSets - auto-discovery of the repositories of every GitHub
# organization of SCM_ORGANIZATIONS (config.env)
# Rendered and applied by vps/scripts/apply-config.sh: one scmProvider generator
# per organization (templates/argocd/generator-{alpha,prod}.yaml.tpl).
#
# Each generator carries the image path of its organization in values.imageBase
# (REGISTRY_HOST/<organization, lowercased>, or REGISTRY_BASE for a single
# organization): Applications use the image {{values.imageBase}}/{{repository}}.
# Repository names must be unique across the organizations: they name the
# Applications and the namespaces (<repository>-alpha, <repository>-prod).
#
# Each Application belongs to the AppProject <repository>, and deploys into the
# namespaces created by vps/scripts/onboard-app.sh (templates/onboarding/):
# Argo CD creates neither of them. A repository that is not onboarded gets no
# Application (the ApplicationSet skips it and retries every 3 minutes).
#
# The scm-token Secret is managed by export-secrets.sh set-scm-credentials,
# never here (it would be overwritten with empty values).
#
# Image Updater v1.1.0+ reads the annotations below through the ImageUpdater
# CRs of manifests/argocd-image-updaters.yaml (useAnnotations: true).
# =============================================================================

---
# ApplicationSet - Alpha environments (develop branch, when the repository has one)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
    name: autodiscover-alpha
    namespace: argocd
spec:
    generators:
${ALPHA_GENERATORS}
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
                argocd-image-updater.argoproj.io/image-list: "app={{values.imageBase}}/{{repository}}"
                argocd-image-updater.argoproj.io/app.update-strategy: newest-build
                # Only deploy immutable builds created from the develop branch (CI tag develop-<full sha>)
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^develop-[a-f0-9]{40}$"
                argocd-image-updater.argoproj.io/write-back-method: argocd
                argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
                argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
        spec:
            # AppProject of onboard-app.sh: its repository and its namespaces only
            project: "{{repository}}"
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
                            value: "{{values.imageBase}}/{{repository}}"
                        -   name: image.tag
                            value: develop
            destination:
                server: https://kubernetes.default.svc
                namespace: "{{repository}}-alpha"
            syncPolicy:
                automated:
                    prune: true
                    selfHeal: true

---
# ApplicationSet - Production environments (main branch)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
    name: autodiscover-prod
    namespace: argocd
spec:
    # A repository that leaves the discovery (token without access, repository
    # renamed or archived) deletes its prod Application: keep the resources it
    # deployed (workloads, Secrets) instead of pruning them with it
    syncPolicy:
        preserveResourcesOnDeletion: true
    generators:
${PROD_GENERATORS}
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
                argocd-image-updater.argoproj.io/image-list: "app={{values.imageBase}}/{{repository}}"
                argocd-image-updater.argoproj.io/app.update-strategy: newest-build
                # Only deploy immutable builds created from the main branch
                argocd-image-updater.argoproj.io/app.allow-tags: "regexp:^main-[a-f0-9]{40}$"
                argocd-image-updater.argoproj.io/write-back-method: argocd
                argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
                argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
        spec:
            # AppProject of onboard-app.sh: its repository and its namespaces only
            project: "{{repository}}"
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
                            value: "{{values.imageBase}}/{{repository}}"
                        -   name: image.tag
                            value: main
            destination:
                server: https://kubernetes.default.svc
                namespace: "{{repository}}-prod"
            # No syncPolicy: no automated sync in production, sync manually once the
            # production SealedSecrets of the application are committed
