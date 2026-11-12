# Runbook - Pod Crash Diagnosis

When a `KubePodCrashLooping`, `KubeContainerHighRestartRate`, or `KubePodOOMKilled` alert fires (or you simply notice a `CrashLoopBackOff`), follow this runbook.

The goal is to move from "pod is broken" to "I know the root cause and what to do" in under 10 minutes.

## 0. Identify the pod

If you're acting on an Alertmanager alert, the labels already contain `namespace`, `pod`, `container`. Otherwise:

```bash
kubectl get pods -A | grep -E "CrashLoopBackOff|Error|ImagePullBackOff"
```

Set environment variables for the rest of the runbook:

```bash
export NS=<namespace>
export POD=<pod-name>
```

## 1. What did the kernel/scheduler see? (30 s)

```bash
kubectl describe pod -n $NS $POD | sed -n '/Containers:/,/Events:/p'
```

Look at `Last State` and `Reason`. Common values:

| Last State Reason | Meaning | Next step |
|-------------------|---------|-----------|
| `OOMKilled` (exit code 137) | Kernel killed the process for using more than `resources.limits.memory` | Section 4 below |
| `Error` (exit code 1) | Application exited with an error | Section 2 (logs) |
| `Error` (exit code 143/SIGTERM) | App was politely terminated and didn't restart cleanly | Section 2 (logs) — usually app-side |
| `ContainerCannotRun` | Image entrypoint failure | Section 3 (image) |
| `ImagePullBackOff` | Image not found or auth failed | Section 3 (image) |
| `CreateContainerConfigError` | Secret/ConfigMap reference is broken | Section 5 (config) |

Also check `Events:` at the bottom: kubelet emits human-readable reasons for probe failures, image pulls, etc.

## 2. Read the previous container's logs (1 min)

The CURRENT container is restarting forever; its logs are usually empty or contain only Spring Boot startup banner. The PREVIOUS container holds the actual crash.

```bash
# Last 200 lines of the previous container (the one that crashed)
kubectl logs -n $NS $POD --previous --tail=200
# Search for the typical Java/Kotlin culprits
kubectl logs -n $NS $POD --previous --tail=2000 | grep -E "ERROR|Exception|Caused by"
```

In Grafana → Explore → Loki, replace the example namespace and pod with actual values.
Logs remain available after pod deletion only while Loki retains them:

```logql
{namespace="my-app-alpha", pod="my-app-alpha-12345"} |= "ERROR"
```

If the previous container logs are also empty, the app died before any log line was written — usually a JVM crash (see core dump) or a misconfigured CMD/ENTRYPOINT.

## 3. Verify the image (1 min)

```bash
kubectl get pod -n $NS $POD -o jsonpath='{.spec.containers[0].image}'
kubectl get pod -n $NS $POD -o jsonpath='{.status.containerStatuses[0].imageID}'
```

If you suspect a regression caused by ArgoCD Image Updater:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=200 | grep $NS
kubectl get application -n argocd <app-name> -o yaml | yq '.status.history[-5:]'
```

Compare the image digest currently running with the one referenced in Git (your Helm values).

## 4. OOMKilled deep dive

```bash
# Hot containers (live)
kubectl top pod -n $NS
```

In Grafana Explore, replace the example namespace and pod in this Prometheus query:

```promql
container_memory_working_set_bytes{namespace="my-app-alpha", pod="my-app-alpha-12345"}
  / kube_pod_container_resource_limits{namespace="my-app-alpha", pod="my-app-alpha-12345", resource="memory"}
```

Common fixes:

- Spring Boot / JVM: ensure `JAVA_OPTS` has `-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0` and that `resources.limits.memory` leaves headroom for non-heap (metaspace, threads, off-heap buffers). A 512Mi limit gives ~384Mi heap, which is tight for reactive Spring Boot.
- Native apps: profile with `pprof` / `heaptrack` and raise limits accordingly.

## 5. Misconfigured Secret/ConfigMap

```bash
kubectl describe pod -n $NS $POD | grep -E "Optional|secret|configmap"
kubectl get secret -n $NS
kubectl get configmap -n $NS
```

If a Secret is missing, check:

- the ArgoCD Application status (`kubectl get app <name> -n argocd`)
- SealedSecrets controller logs (`kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets`)
- onboarding script outputs (`/root/.k3s-secrets/<app>.env`)

## 6. The 2026-05-18 class of bugs (placeholder value)

Seen on an alpha environment ([archived postmortem](archive/postmortem_2026-05-18_alpha_placeholder_keys.md)), and generalizable: a Helm values file shipped a literal placeholder (`<GENERATE_NEW_KEY_PAIR_FOR_X>`) as an env var. The app tried to Base64-decode it at startup, failed, and crashed.

Detection signal in logs: `IllegalArgumentException: Illegal base64 character XX` where XX is a hex value (3c is `<`, 3e is `>`, 24 is `$`).

Search Loki for this pattern across all namespaces:

```logql
{namespace=~".+"} |~ "Illegal base64 character"
```

If you find one, audit the corresponding Helm values for unfilled placeholders before issuing a release.

## 7. The ArgoCD selfHeal cliff

For an alpha Application with `selfHeal: true`, inspect the operation when a structural
problem prevents convergence:

```bash
kubectl get application <app> -n argocd -o yaml | yq '.status.operationState.message'
kubectl get application <app> -n argocd -o yaml | yq '.status.operationState.operation.sync.autoHealAttemptsCount'
```

Fix the underlying issue before syncing again. ApplicationSet can revert a direct patch to
the generated Application; plan any temporary policy change at the ApplicationSet level
and account for its effect on other applications.

## 8. Escalation

If the runbook hasn't given you the answer after the above steps:

1. Capture an artifact bundle: `kubectl describe pod -n $NS $POD > pod.txt` plus current + previous logs plus events.
2. Write a postmortem using `vps/docs/postmortem_template.md`.
3. File an issue on the application repo, attaching the artifacts.
