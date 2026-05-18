# Postmortem - coterie-webapp-alpha placeholder VAPID keys (2026-05-18)

## TL;DR
`coterie-webapp-alpha` had been in **CrashLoopBackOff for 48 consecutive days** (since 2026-03-31), totalling **25 833 container restarts** across two ReplicaSets, without anyone noticing. Root cause: the Helm values file shipped a literal placeholder string `<GENERATE_NEW_KEY_PAIR_FOR_ALPHA>` as the value of `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY`. Spring Boot's WebPush configuration tried to Base64-decode the placeholder at startup, failed with `IllegalArgumentException: Illegal base64 character 3c`, and the entire application context refused to start. ArgoCD's `selfHeal: true` retried **13 762 times** with no chance of converging because the bug was structural.

## Facts
| Field | Value |
|-------|-------|
| Incident date | 2026-03-31 11:21:13 UTC -> 2026-05-18 (ongoing at investigation) |
| Detection date | 2026-05-18 (manual operator inquiry; no alert ever fired) |
| Severity | High (alpha environment, but 0% availability for 48 days) |
| Component(s) | `coterie-webapp-alpha` (k8s ns), `coterie-webapp` ArgoCD Application, Helm chart `helm/coterie-webapp/values-alpha.yaml` |
| Detection source | Manual SSH investigation |
| User-facing impact | `alpha.macoterie.fr` returned 5xx (no upstream pod ready) since 2026-03-31 |

## Timeline (UTC)
- ~2026-03-30 - PR introducing Web Push merged into `develop`. `values-alpha.yaml` ships `VAPID_PUBLIC_KEY: "<GENERATE_NEW_KEY_PAIR_FOR_ALPHA>"` and a matching private-key placeholder.
- 2026-03-31 11:21:13 - ArgoCD syncs revision `f3dd5cd`, creates ReplicaSet `coterie-webapp-alpha-646cbd766b`. First container starts.
- 2026-03-31 11:22:xx - First crash: `Caused by: java.lang.IllegalArgumentException: Illegal base64 character 3c` during Spring context refresh. Pod exits with code 1.
- 2026-03-31 -> 2026-05-18 - K8s kubelet restarts the container every ~80 s. ArgoCD `selfHeal` retries the sync (13 762 attempts logged).
- 2026-05-18 11:53:23 - Last observed crash captured in `--previous` logs at the time of investigation.
- 2026-05-18 11:58:30 - Diagnostic script runs on VPS via SSH; archive packaged.
- 2026-05-18 12:10 - Root cause identified from `--previous` stack trace.
- 2026-05-18 - Fix prepared in `helm/coterie-webapp/values-alpha.yaml` (remove placeholder env vars).

## Root cause
Two contributors:

1. **Helm values mistake** - `helm/coterie-webapp/values-alpha.yaml:107-110` shipped:
   ```yaml
   - name: VAPID_PUBLIC_KEY
     value: "<GENERATE_NEW_KEY_PAIR_FOR_ALPHA>"
   - name: VAPID_PRIVATE_KEY
     value: "<GENERATE_NEW_KEY_PAIR_FOR_ALPHA>"
   ```
   `values-prod.yaml` for the same chart correctly references a `SealedSecret` via `valueFrom.secretKeyRef`. Alpha never received the same wiring; the unfilled placeholder was committed and deployed.

2. **Insufficient defensive coding** - `WebPushProperties.isConfigured()` (Kotlin) only checked `publicKey.isNotBlank() && privateKey.isNotBlank()`. The placeholder string is not blank, so `isConfigured()` returned true and the WebPush bean tried to actually use the value. The underlying webpush library (`nl.martijndwars.webpush`) Base64-decodes the public key in `loadPublicKey(Utils.java:49)`, fails on the `<` character (0x3c), bubbles up an `IllegalArgumentException`, and Spring aborts context refresh.

## Evidence
From `kubectl logs --previous`:

```
2026-05-18 11:54:49.851 ERROR SpringApplication - Application run failed
org.springframework.beans.factory.UnsatisfiedDependencyException: Error creating bean
    with name 'webPushDeliveryAdapter' [...]
    Factory method 'webPushDeliveryAdapter' threw exception with message:
    Illegal base64 character 3c
[...]
Caused by: java.lang.IllegalArgumentException: Illegal base64 character 3c
    at java.base/java.util.Base64$Decoder.decode0(...)
    at nl.martijndwars.webpush.Utils.loadPublicKey(Utils.java:49)
    at com.coterie.infrastructure.configuration.WebPushConfiguration
        .webPushDeliveryAdapter(WebPushConfiguration.kt:50)
```

ArgoCD Application state:

```yaml
status:
  sync: { status: OutOfSync, revision: f3dd5cd4f9eacb4a2780f3167bcb21f18ed49f54 }
  health: { status: Degraded }
  operationState:
    operation:
      sync:
        autoHealAttemptsCount: 13762
```

Pod state (one of two ReplicaSets):
```
coterie-webapp-alpha-577dc97865-jc9t5  0/1  Running  15123 (6m34s ago)  68d
coterie-webapp-alpha-646cbd766b-kx9gp  0/1  CrashLoopBackOff  10710 (3m45s ago)  48d
```

## Why didn't we catch it earlier
1. **Alertmanager was disabled** in `vps/values/prometheus.yaml` (`alertmanager.enabled: false`). No alert ever fired for `KubePodCrashLooping` or `KubeContainerHighRestartRate`.
2. **No log aggregation** - the `--previous` container's stack trace was only retrievable as long as the pod hadn't been pruned by the kubelet. Anyone glancing at the cluster a week later would have lost the evidence.
3. **No dashboard focused on restarts** - the 3 pre-installed dashboards (cluster, node, postgres) don't surface container restart counts prominently.
4. **No team review of ArgoCD selfHeal counters** - `autoHealAttemptsCount: 13762` is the signature of a structurally broken sync, but nothing surfaced it.
5. **ArgoCD's auto-heal masked the symptom** - because the sync technically "succeeded" at the API level (resources applied), no visible "failed sync" alert was raised. The failure was at the runtime (pod) layer, not the desired-state-vs-live-state layer.

## Resolution
1. `helm/coterie-webapp/values-alpha.yaml` - removed the placeholder env vars (kept a comment explaining the trade-off and how to enable WebPush in alpha later via SealedSecret, mirroring prod).
2. `coterie-infrastructure/.../WebPushProperties.kt` - hardened `isConfigured()` to detect placeholder patterns (`<...>`, `${...}`, literal `TODO`/`CHANGEME`/`REPLACE_ME`). Added unit tests including a regression test for this exact incident.
3. `vps/values/prometheus.yaml` - enabled Alertmanager and added 9 pod/node alerting rules covering the conditions we missed.
4. `vps/values/loki.yaml` + `vps/values/promtail.yaml` - deployed centralized log aggregation so `--previous` logs survive pod recycling.
5. `vps/values/grafana.yaml` - added Loki datasource and 4 new dashboards focused on pod restarts and log exploration.
6. New docs: `vps/docs/observability.md`, `vps/docs/runbook_pod_crashes.md`, `vps/docs/postmortem_template.md`.

## Action items
- [x] Fix placeholder in `values-alpha.yaml` (owner: code, status: done, 2026-05-18)
- [x] Harden `WebPushProperties.isConfigured()` (owner: code, status: done, 2026-05-18)
- [x] Enable Alertmanager + alerting rules (owner: k3s-stack, status: done, 2026-05-18)
- [x] Deploy Loki + Promtail (owner: k3s-stack, status: done, 2026-05-18)
- [x] Add pod-crash dashboards (owner: k3s-stack, status: done, 2026-05-18)
- [x] Document observability stack and crash runbook (owner: k3s-stack, status: done, 2026-05-18)
- [ ] Configure Discord webhook receiver in Alertmanager (owner: operator, due: next session)
- [ ] Audit all `helm/*/values-*.yaml` files for remaining `<PLACEHOLDER>` strings (owner: code, due: next session)
- [ ] Investigate why `coterie-webapp-prod` is in `Missing` state (owner: operator, due: next session)
- [ ] Consider an ArgoCD `selfHeal` circuit-breaker after N attempts (owner: k3s-stack, due: backlog)
- [ ] Plan K3s + Gateway API upgrade (currently v1.29.0+k3s1 / v1.2.0, latest are v1.36.0+k3s1 / v1.5.1) (owner: k3s-stack, due: backlog)

## Lessons learned
- **Class of bug**: silent placeholder values that pass simple "not blank" checks but break downstream parsers. This affects any string that's later interpreted as Base64, URL, JSON, etc. The defensive `looksLikePlaceholder()` check we added in `WebPushProperties` should be applied to other similar configuration classes (CAPTCHA keys come to mind).
- **Detection gap**: alerts on metrics already gathered by `kube-state-metrics` were one config flag away from being delivered. Cost of enabling: zero.
- **Process gap**: no team ritual to review ArgoCD health weekly. A 30-second `kubectl get applications -n argocd` would have caught this 48 days earlier.
- **Architecture decision**: ArgoCD `selfHeal: true` is convenient for transient issues but can hide structural failures indefinitely. A finite retry budget would surface "this can never converge" earlier.

## References
- Runbook: [`runbook_pod_crashes.md`](runbook_pod_crashes.md)
- Observability stack overview: [`observability.md`](observability.md)
- Previous related postmortem (ArgoCD sync stagnation, same env): [`postmortem_2026-02-14_argocd_sync.md`](postmortem_2026-02-14_argocd_sync.md)
- Local forensic artifact bundle (operator-side): `C:\Users\oldon\vps-investigation-20260518T133259Z\artifacts\`
