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

### Pod-level
- **KubePodCrashLooping** (critical, 5m) — fires when a container is in CrashLoopBackOff. Would have caught the 2026-05-18 incident **in 5 minutes** instead of 48 days.
- **KubeContainerWaiting** (warning, 10m) — fires when a container is stuck waiting for a non-trivial reason (ImagePullBackOff, ErrImagePull, CreateContainerConfigError…).
- **KubePodOOMKilled** (warning, 1m) — fires when a container was killed by the kernel OOM killer.
- **KubePodNotReady** (warning, 15m) — fires when a non-Job pod is stuck Pending/Unknown/Failed for >15m.
- **KubeDeploymentReplicasMismatch** (warning, 15m) — fires when desired replicas != available replicas and rollout has stalled.
- **KubeJobFailed** (warning, 5m) — fires when a Job (including ArgoCD PreSync migrations) failed.
- **KubeContainerHighRestartRate** (warning, 10m) — fires when a container restarts >1/min on average over 15 min.

### Node-level
- **NodeMemoryPressure** (critical, 5m) — fires when MemAvailable < 10%.
- **NodeDiskPressure** (warning, 10m) — fires when free space on any filesystem < 10%.

To add your own rules, just append entries under the appropriate `groups[].rules` list, then `helm upgrade prometheus prometheus-community/prometheus -n monitoring -f vps/values/prometheus.yaml`.

## Configuring Discord notifications (Alertmanager)

By default Alertmanager has a single `null` receiver — it groups and stores alerts in its UI but does NOT send them anywhere. To enable Discord:

1. Create a Discord webhook in your server settings: Server Settings → Integrations → Webhooks → New Webhook. Note its URL (`https://discord.com/api/webhooks/<ID>/<TOKEN>`).
2. **Important**: append `/slack` to the URL. Discord supports Slack-compatible webhook payloads, which is what Alertmanager's `webhook_configs` emits.
3. Edit `vps/values/prometheus.yaml`, uncomment the `discord` receiver and the matching route, and replace the URL.
4. `helm upgrade prometheus prometheus-community/prometheus -n monitoring -f vps/values/prometheus.yaml`.
5. Verify with `amtool` from inside the alertmanager pod or by triggering a test alert (e.g. `kubectl scale deploy/coterie-webapp -n <ns> --replicas=0` for a few minutes).

For sensitive setups, store the webhook URL in a Kubernetes Secret and reference it via `valueFrom.secretKeyRef` in `alertmanagerFiles` (requires a small adapter — open an issue if you need this).

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
