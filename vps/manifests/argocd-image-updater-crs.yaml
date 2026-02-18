# =============================================================================
# Argo CD Image Updater - Custom Resources
# Required by argocd-image-updater v1.1.0+ (CRD-based, not annotation-based)
# =============================================================================
#
# Generated from template. Do not edit directly.
# Edit vps/config.env and run: ./vps/scripts/apply-config.sh
#
# These CRs tell the Image Updater which Applications to watch.
# Image configuration (registry, strategy, tag filter, helm mapping) is read
# from annotations on the Applications themselves (useAnnotations: true).
#
# =============================================================================

---
# ImageUpdater CR - Alpha environments
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
    name: image-updater-alpha
    namespace: argocd
    labels:
        app.kubernetes.io/component: image-updater
        app.kubernetes.io/environment: alpha
        app.kubernetes.io/managed-by: k3s-stack
spec:
    namespace: argocd
    applicationRefs:
        -   namePattern: "*-alpha"
            useAnnotations: true

---
# ImageUpdater CR - Production environments
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
    name: image-updater-prod
    namespace: argocd
    labels:
        app.kubernetes.io/component: image-updater
        app.kubernetes.io/environment: prod
        app.kubernetes.io/managed-by: k3s-stack
spec:
    namespace: argocd
    applicationRefs:
        -   namePattern: "*-prod"
            useAnnotations: true
