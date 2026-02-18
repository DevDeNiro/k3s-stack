# Postmortem: ArgoCD Sync & Deployment Stagnation (2026-02-14)

## Incident Summary

**Date:** 2026-02-14  
**Component:** ArgoCD / coterie-webapp-alpha  
**Severity:** Medium (Stale deployment on alpha environment)

## Issue Description

The `coterie-webapp-alpha` application in ArgoCD was reporting an `OutOfSync` and `Degraded` status. More critically,
the running Pod was 9 days old, meaning the latest code changes pushed to the `develop` branch were not being deployed,
despite the CI pipeline presumably passing.

## Root Cause Analysis

1. **Missing ServiceAccount:** The `ServiceAccount` for `coterie-webapp-alpha` was missing in the namespace. This
   prevented new ReplicaSets from spinning up pods (Error: `serviceaccount "coterie-webapp-alpha" not found`).
2. **Floating Tag & Deployment Strategy:** The application uses the image tag `develop`. This is a "floating" (mutable)
   tag.
    - Kubernetes does not automatically pull a new image for an existing Pod unless the `imagePullPolicy` is `Always` (
      which it was) AND the Pod is restarted or recreated.
    - ArgoCD operates on the principle of "Desired State" vs "Live State". If the Helm Chart continues to specify
      `tag: develop` and the live Deployment specifies `tag: develop`, ArgoCD sees **no drift**, even if the underlying
      image hash in the registry has changed. Therefore, it does not trigger a Deployment rollout.

## Resolution Steps

1. **Controller Restart:** Attempted to restart `argocd-application-controller` (did not resolve the sync issue).
2. **Force Sync:** Forced a sync using `kubectl patch`, but the status remained `OutOfSync`.
3. **Manual Cleanup:** Deleted the `Service` and `ServiceAccount` resources to force recreation.
4. **Discovery of Missing Resource:** Identified that the `ServiceAccount` was not being recreated automatically.
5. **Force Replace:** Used ArgoCD sync options `Replace=true` and `force=true` to successfully recreate the missing
   ServiceAccount.
6. **Deployment Restart:** Manually triggered `kubectl rollout restart deployment` to force the Pod to terminate and
   pull the new image manifest.

## Corrective Actions & Improvements

To prevent recurrence and ensure Continuous Deployment (CD) actually deploys new code:

1. **Investigate Auto-Discovery/Image Updater:** Ensure `argocd-image-updater` is correctly configured to track image
   digests (SHAs) rather than just tags, OR update the CI pipeline to commit a unique tag (e.g., git short sha) to the
   Helm values repo.
2. **Resource Ownership:** Verify why the ServiceAccount disappeared (manual deletion vs. pruning issue).
3. **Pipeline Robustness:** Review `vps-deployment.md` and scripts to ensure they handle the `develop` branch updates
   correctly (potentially adding a `rollout restart` annotation or using a checksum of the values to force pod
   rotation).
