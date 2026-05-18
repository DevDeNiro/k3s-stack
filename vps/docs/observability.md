# Observability Stack

The k3s-stack ships a complete observability stack tuned for a 4-6 GB VPS:

| Component | Role | Memory | Persistent storage |
|-----------|------|--------|--------------------|
| Prometheus | Metrics scrape + alerting rules | ~256 Mi | 5 Gi |
| Alertmanager | Alert routing + grouping | ~64 Mi | 1 Gi |
| Loki (SingleBinary) | Log aggregation, LogQL queries | ~256 Mi | 5 Gi |
| Promtail (DaemonSet) | Ships `/var/log/pods/*.log` to Loki | ~128 Mi | - |
| Grafana | Dashboards + Explore (Prom + Loki + AM) | ~256 Mi | 2 Gi |
| Node Exporter | Host metrics | ~64 Mi | - |
| kube-state-metrics | K8s object metrics | ~64 Mi | - |

Total steady-state: ~1.0 GiB (leaves room for the application workloads).

## Why we have this stack
On 2026-05-18 we discovered that `coterie-webapp-alpha` had been in CrashLoopBackOff for **48 days** (25 833 cumulative container restarts) without anyone noticing. See [`postmortem_2026-05-18_coterie_alpha_vapid.md`](postmortem_2026-05-18_coterie_alpha_vapid.md) for the full root-cause analysis.
The observability stack is the corrective action: alerts, centralized logs, and dashboards specifically focused on **container restarts and pod health**.

## Access

| Tool | Default access |
|------|----------------|
| Grafana | `kubectl port-forward -n monitoring svc/grafana 3000:80` then http://localhost:3000 |
| Prometheus | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` then http://localhost:9090 |
| Alertmanager | `kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:80` then http://localhost:9093 |
| Loki API | `kubectl port-forward -n monitoring svc/loki 3100:3100` then http://localhost:3100 |
Credentials are managed via `vps/scripts/export-secrets.sh show grafana`.

## Pre-loaded dashboards (Grafana)

| ID | Title | Datasource | Why it's there |
|----|-------|------------|----------------|
| 6417 | Kubernetes Cluster Monitoring | Prometheus | Cluster-wide health (pre-existing) |
| 1860 | Node Exporter Full | Prometheus | Host metrics (pre-existing) |
| 9628 | PostgreSQL | Prometheus | DB metrics (pre-existing) |
| 15760 | Kubernetes / Views / Pods | Prometheus | **Restart counts, container states, memory/CPU per pod** |
| 15757 | Kubernetes / Views / Global | Prometheus | Cluster-wide health badges |
| 13639 | Loki Logs / App | Loki | LogQL log explorer per namespace/pod |
| 9578 | Alertmanager | Prometheus | Alert overview |

## Alerting rules

All rules live in `vps/values/prometheus.yaml` under `serverFiles.alerting_rules.yml`.

### Pod-level (group `kubernetes-pods`)
- **KubePodCrashLooping** (critical, 5m) — fires when a container is in CrashLoopBackOff. Would have caught the 2026-05-18 incident **in 5 minutes** instead of 48 days.
- **KubeContainerWaiting** (warning, 10m) — fires when a container is stuck waiting for a non-trivial reason (ImagePullBackOff, ErrImagePull, CreateContainerConfigError…).
- **KubePodOOMKilled** (warning, 1m) — fires when a container was killed by the kernel OOM killer.
- **KubePodNotReady** (warning, 15m) — fires when a non-Job pod is stuck Pending/Unknown/Failed for >15m.
- **KubeDeploymentReplicasMismatch** (warning, 15m) — fires when desired replicas != available replicas and rollout has stalled.
- **KubeJobFailed** (warning, 5m) — fires when a Job (including ArgoCD PreSync migrations) failed.
- **KubeContainerHighRestartRate** (warning, 10m) — fires when a container restarts >1/min on average over 15 min.

### Node-level (group `node-health`)
- **NodeMemoryPressure** (critical, 5m) — fires when MemAvailable < 10%.
- **NodeDiskPressure** (warning, 10m) — fires when free space on any filesystem < 10%.

### Application-level (groups `app-*`)
Ported from `coterie-webapp/docker/observability/alert_rules.yml`. All metrics carry `application="coterie-webapp"` (Micrometer common tag) plus `namespace` (Prometheus relabel), so each alert fires once per `(application, namespace)` pair (i.e. once for alpha and once for prod).
- **HighP95Latency / CriticalP99Latency** — latency SLO breaches on `http_server_requests_seconds_bucket`.
- **SlowDatabaseQueries** — mean `r2dbc_pool_acquire_seconds` > 100 ms for 2 minutes.
- **HighErrorRate / CriticalErrorRate** — 5xx ratio > 1% (warn) / > 5% (crit).
- **ExternalServiceFailures** — `coterie_external_send_email_failure_total` rate > 0.1/s.
- **AppScrapeDown** — `up{job="kubernetes-pods", namespace=~"coterie-webapp-.*"} == 0` for >1m (pod is up, but `/actuator/prometheus` is unreachable).
- **CircuitBreakerOpen / CircuitBreakerHalfOpen / HighRetryRate** — Resilience4j signals.
- **ConnectionPoolExhausted / ConnectionPoolCritical** — R2DBC pool saturation.
- **HighJvmMemoryUsage** — heap > 85% for 5m.

To add your own rules, just append entries under the appropriate `groups[].rules` list, then `helm upgrade prometheus prometheus-community/prometheus -n monitoring -f vps/values/prometheus.yaml`.

## Configuring Discord notifications (Alertmanager)

The Alertmanager config now ships with a `discord` receiver wired to all `severity=critical|warning` alerts. It reads the webhook URL from a file mounted via `alertmanager.extraSecretMounts` (the Secret is `monitoring/alertmanager-discord-webhook`, key `webhook-url`). Until you create that Secret, Alertmanager will still group and display alerts in its UI, but send attempts will fail silently — it will retry once the Secret appears, no restart required.

### Create / rotate the webhook (one command)
```bash
sudo ./vps/scripts/setup-secrets.sh set-discord-webhook
```
The script prompts you for the URL, validates the host, auto-appends `/slack` if missing (Discord rejects Alertmanager's payload format without it), and writes the Secret atomically. Re-running rotates the URL.

### Pick up the new mount
The Secret is mounted with `optional: true` so Alertmanager doesn't crash if you `helm upgrade` before creating it. Once the Secret exists, kubelet sync will eventually project the file; force it immediately with:
```bash
kubectl rollout restart deployment/prometheus-alertmanager -n monitoring
```

### Verify end-to-end
```bash
# Inject a synthetic alert through alertmanager itself:
kubectl -n monitoring exec deploy/prometheus-alertmanager -- \
    amtool alert add 'alertname=DiscordTest' severity=warning
```
Within ~30 s (`group_wait`), a Slack-formatted message should land in your Discord channel. If nothing arrives, check `kubectl -n monitoring logs deploy/prometheus-alertmanager | grep -i discord` — the most common cause is forgetting the `/slack` suffix.

## Application dashboards (shipped by `coterie-webapp` chart)

The Grafana chart now runs a dashboard sidecar that watches the cluster for ConfigMaps labelled `grafana_dashboard=1` across **all namespaces** (`sidecar.dashboards.searchNamespace: ALL`). This is how application charts deliver their own dashboards without touching this monitoring stack.

The `coterie-webapp` Helm chart ships `Coterie Overview` and `Coterie SLO & Latency` via `helm/coterie-webapp/templates/grafana-dashboards-cm.yaml`. They appear automatically in Grafana under the folder generated from the ConfigMap (no manual import). Datasource UIDs are pinned (`prometheus`, `loki`, `alertmanager`) so the dashboards keep working across Grafana reinstalls.

To add another dashboard:
1. Drop its `.json` into `coterie-webapp/helm/coterie-webapp/dashboards/`.
2. `helm upgrade coterie-webapp ...` (or let ArgoCD sync).
3. Sidecar logs (`kubectl logs -n monitoring deploy/grafana -c grafana-sc-dashboard`) confirm pickup.

If you want to disable shipped dashboards for a deployment, set `monitoring.dashboards.enabled: false` in the chart values.

## Querying logs (LogQL)

Loki uses LogQL, a Prometheus-like query language for logs. Some recipes:

```logql
# All logs of the alpha namespace, last 24h
{namespace="coterie-webapp-alpha"}

# Only ERROR-level entries
{namespace="coterie-webapp-alpha"} |= "ERROR"

# Spring Boot exception names (regex)
{namespace="coterie-webapp-alpha"} |~ "Caused by:.*Exception"

# Filter by pod
{namespace="coterie-webapp-alpha", pod=~"coterie-webapp-alpha-.*"}

# Count errors per minute
sum by (pod) (rate({namespace="coterie-webapp-alpha"} |= "ERROR" [1m]))
```

Use Grafana → Explore → Loki datasource for an interactive UI.

## Notes for VPS upgrades

When upgrading the stack:

```bash
helm repo update
helm upgrade prometheus prometheus-community/prometheus -n monitoring -f vps/values/prometheus.yaml
helm upgrade grafana grafana/grafana -n monitoring -f vps/values/grafana.yaml
helm upgrade loki grafana/loki -n monitoring -f vps/values/loki.yaml
helm upgrade promtail grafana/promtail -n monitoring -f vps/values/promtail.yaml
```

To wipe Loki storage (if schemas conflict after a major version bump):
```bash
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=loki
```
(then re-run `helm upgrade loki ...`).

## Architecture diagram

```
                   ┌─────────────────────────────────┐
                   │            VPS (K3s)            │
                   │                                 │
  Pods (all NS) ───┼──► /var/log/pods/*.log ──┐      │
                   │                          │      │
                   │                          ▼      │
                   │                   ┌──────────┐  │
                   │                   │ Promtail │  │
                   │                   │ DaemonSet│  │
                   │                   └─────┬────┘  │
                   │                         │       │
                   │                         ▼       │
                   │                   ┌──────────┐  │
                   │                   │   Loki   │  │
                   │                   │  (PV 5G) │  │
                   │                   └─────▲────┘  │
                   │                         │       │
                   │  metrics scrape         │ logs  │
                   │ ┌──────────────┐        │       │
  All pods    ─────┼─► Prometheus   │        │       │
  /metrics         │ │  (PV 5G)     │        │       │
                   │ └─┬────────────┘        │       │
                   │   │                     │       │
                   │   │ fires               │       │
                   │   ▼                     │       │
                   │ ┌──────────────┐        │       │
                   │ │ Alertmanager │        │       │
                   │ │  (PV 1G)     │        │       │
                   │ └─┬────────────┘        │       │
                   │   │                     │       │
                   │   │ (Discord/Slack)     │       │
                   │   ▼                     │       │
                   │   external             ┌┴─────┐ │
                   │                        │      │ │
                   │                  ┌─────► Graf │ │
                   │                  │     │ ana  │ │
                   │                  │     │ (PV2)│ │
                   │                  │     └──────┘ │
                   │   ───────────────┘              │
                   └──────────────────────────────────┘
```
