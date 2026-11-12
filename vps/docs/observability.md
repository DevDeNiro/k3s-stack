# Observability Stack

The k3s-stack ships a complete observability stack tuned for a 4-6 GB VPS:

| Component | Role | Memory | Persistent storage |
|-----------|------|--------|--------------------|
| Prometheus | Metrics scrape + alerting rules | ~320 Mi (limit 768 Mi) | 5 Gi |
| Alertmanager | Alert routing + grouping | ~64 Mi | 1 Gi |
| Loki (Monolithic) | Log aggregation, LogQL queries | ~256 Mi | 5 Gi |
| Alloy (DaemonSet) | Ships `/var/log/pods/*.log` to Loki | limit 128 Mi + 32 Mi reloader | node-local positions |
| Grafana | Dashboards + Explore (Prom + Loki + AM) | ~256 Mi | 2 Gi |
| Node Exporter | Host metrics | ~64 Mi | - |
| kube-state-metrics | K8s object metrics | ~64 Mi | - |

Total steady-state: ~1.0 GiB (leaves room for the application workloads).

## Why we have this stack
On 2026-05-18 we discovered that the alpha environment of an application had been in CrashLoopBackOff for **48 days** (25 833 cumulative container restarts) without anyone noticing. See the [archived postmortem](archive/postmortem_2026-05-18_alpha_placeholder_keys.md) for the full root-cause analysis.
The observability stack is the corrective action: alerts, centralized logs, and dashboards specifically focused on **container restarts and pod health**.

## Access

| Tool | Default access |
|------|----------------|
| Grafana | `kubectl port-forward -n monitoring svc/grafana 3000:80` then http://localhost:3000 |
| Prometheus | `kubectl port-forward -n monitoring svc/prometheus-server 9090:80` then http://localhost:9090 |
| Alertmanager | `kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093` then http://localhost:9093 |
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
They apply to every application exposing Micrometer metrics with an `application` tag (Spring Boot: `management.metrics.tags.application=<name>`); the scrape job adds `namespace`, so each alert fires once per `(application, namespace)` pair (once for alpha, once for prod). Applications without these metrics are not concerned. Alerts on business metrics of one application belong to that application.
- **HighP95Latency / CriticalP99Latency** — latency SLO breaches on `http_server_requests_seconds_bucket`.
- **SlowDatabaseQueries** — mean `r2dbc_pool_acquire_seconds` > 100 ms for 2 minutes.
- **HighErrorRate / CriticalErrorRate** — 5xx ratio > 1% (warn) / > 5% (crit).
- **AppScrapeDown** — `up{job="kubernetes-pods", namespace=~".+-(alpha|prod)"} == 0` for >1m in the application namespaces (pod is up, but its metrics endpoint is unreachable).
- **CircuitBreakerOpen / CircuitBreakerHalfOpen / HighRetryRate** — Resilience4j signals.
- **ConnectionPoolExhausted / ConnectionPoolCritical** — R2DBC pool saturation.
- **HighJvmMemoryUsage** — heap > 85% for 5m.

To add your own rules, append entries under the appropriate `groups[].rules` list, then apply them with the pinned chart version (see [Notes for VPS upgrades](#notes-for-vps-upgrades)).

## Configuring Discord notifications (Alertmanager)

The Alertmanager configuration (`alertmanager.config` in `vps/values/prometheus.yaml`) routes every `severity=critical|warning` alert to a `discord` receiver that uses Alertmanager's native Discord integration (`discord_configs`). The webhook URL is read from a file mounted with `alertmanager.extraSecretMounts` (Secret `monitoring/alertmanager-discord-webhook`, key `webhook-url`). Until the Secret exists, Alertmanager still groups and displays the alerts in its UI; the sends fail and are retried.

> Before this configuration, the routing lived under `alertmanagerFiles`, a key the current chart ignores: no alert was ever sent.

### Create / rotate the webhook
```bash
sudo ./vps/scripts/setup-secrets.sh set-discord-webhook
```
The script prompts for the URL without echo (Discord: Server Settings > Integrations > Webhooks > Copy Webhook URL), checks the host and removes a `/slack` suffix if present (the Slack-compatible endpoint is not used). Re-running rotates the URL.

### Pick up the new mount
The Secret is mounted with `optional: true`; the kubelet projects the file once it exists. To apply it immediately:
```bash
kubectl rollout restart statefulset/prometheus-alertmanager -n monitoring
```

### Verify end-to-end
```bash
kubectl exec -n monitoring prometheus-alertmanager-0 -c alertmanager -- \
    amtool --alertmanager.url=http://localhost:9093 alert add DiscordTest severity=warning
```
Within ~30 s (`group_wait`) a message lands in the Discord channel. Otherwise: `kubectl logs -n monitoring prometheus-alertmanager-0 -c alertmanager | grep -i discord`.

## Application dashboards (shipped by the application charts)

The Grafana chart runs a dashboard sidecar that watches the cluster for ConfigMaps labelled `grafana_dashboard=1` across **all namespaces** (`sidecar.dashboards.searchNamespace: ALL`). This is how application charts deliver their own dashboards without touching this monitoring stack.

An application chart renders its dashboards into such a ConfigMap (for example `helm/<app>/templates/grafana-dashboards-cm.yaml` reading the JSON files of `helm/<app>/dashboards/`). They appear automatically in Grafana under the folder generated from the ConfigMap (no manual import). Reference the pinned datasource UIDs (`prometheus`, `loki`, `alertmanager`) so the dashboards keep working across Grafana reinstalls.

To add a dashboard:
1. Drop its `.json` into `helm/<app>/dashboards/` of the application repository.
2. `helm upgrade <app> ...` (or let Argo CD sync).
3. Sidecar logs (`kubectl logs -n monitoring deploy/grafana -c grafana-sc-dashboard`) confirm pickup.

Turning the shipped dashboards off is up to the application chart (for example a `monitoring.dashboards.enabled` value).

## Querying logs (LogQL)

Loki uses LogQL, a Prometheus-like query language for logs. Some recipes:

```logql
# All logs of the alpha namespace, last 24h
{namespace="my-app-alpha"}

# Only ERROR-level entries
{namespace="my-app-alpha"} |= "ERROR"

# Spring Boot exception names (regex)
{namespace="my-app-alpha"} |~ "Caused by:.*Exception"

# Filter by pod
{namespace="my-app-alpha", pod=~"my-app-alpha-.*"}

# Count errors per minute
sum by (pod) (rate({namespace="my-app-alpha"} |= "ERROR" [1m]))
```

Use Grafana → Explore → Loki datasource for an interactive UI.

### Gateway access logs and redaction

The NGINX data plane writes one JSON line per request (`vps/values/nginx-gateway-fabric.yaml`, NginxProxy
`logging.accessLog`): `time`, `remote_addr`, `host`, `method`, `path` (without the query string), `protocol`,
`status`, `body_bytes_sent`, `request_time`, `upstream_status`, `upstream_response_time`, `user_agent`. The
query string and the Referer header are never logged: they carry OAuth codes, states and tokens.

Before Loki, two Alloy `replace` stages (`vps/values/alloy.yaml`) mask, in the lines of every pod, the token
of `/stop/<token>` paths and the values of the `code`, `state`, `session_state` and `id_token_hint` query
parameters (`<redacted>`). The raw lines stay in the node files (`/var/log/pods/`) until the kubelet rotates them:
see [`security-hardening.md`](security-hardening.md).

```logql
# Requests answered 429 (rate limits), per host
sum by (host) (count_over_time({namespace="nginx-gateway"} | json | status="429" [5m]))

# 401 and 403 answers per path
sum by (path) (count_over_time({namespace="nginx-gateway"} | json | status=~"401|403" [15m]))

# Slow requests (seconds)
{namespace="nginx-gateway"} | json | request_time > 1
```

## Notes for VPS upgrades

Chart versions in `vps/config/versions.env` are defaults for new installations, not proof
of the versions currently running. **Do not rerun the fresh-server installer as a
migration procedure.** Record the installed release revisions and custom values, check
release notes, back up all affected persistent volumes and test restores and upgrades on
an isolated copy first. In particular, verify that PostgreSQL dumps contain every expected
database: a backup job can currently succeed despite a failed individual dump.

Grafana and Loki now use the `grafana-community` repository; Alloy remains in `grafana`.
The Grafana chart uses a distroless image and a read-only filesystem. Validate plugins,
dashboards and authentication in the test environment before changing production.

Loki's community chart calls the former `SingleBinary` deployment mode `Monolithic`
while retaining the `singleBinary` values key. The rendered StatefulSet, services and
PVC template have the same names and selectors with the values in this repository, but
that does **not** prove a live upgrade or rollback is safe. Preserve the existing Loki PVC
and schema, test data readability and ingestion on a restored copy, and follow the
[official community migration guide](https://grafana.com/docs/loki/latest/setup/upgrade/upgrade-to-community/).
Do not delete a PVC to resolve a schema or upgrade error.

After that preparation, configure the repositories and use the pinned chart versions for
the components individually, checking each rollout before proceeding:

```bash
source vps/config/versions.env
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
helm repo update
helm upgrade prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" -n monitoring -f vps/values/prometheus.yaml
helm upgrade grafana grafana-community/grafana --version "$GRAFANA_CHART_VERSION" -n monitoring -f vps/values/grafana.yaml
helm upgrade loki grafana-community/loki --version "$LOKI_CHART_VERSION" -n monitoring -f vps/values/loki.yaml
```

### Promtail to Alloy cutover

Promtail is end-of-life. The complete Promtail chart configuration was converted to
`vps/values/alloy.yaml`, including pod discovery, labels, CRI/Docker stages, redaction,
the noisy-pod filter and retries. The chart exposes different Alloy metrics: review any
Promtail-specific alerts or dashboards.

The historical pipeline applies `cri` and then `docker` to every line. An application
JSON message containing a `log` field may therefore be interpreted as a Docker envelope:
other fields can disappear and its timestamp or stream can change. This inherited
behavior is retained for compatibility; test application log formats before cutover.

Plan a maintenance window and rehearse on a restored isolated copy first:

1. Compare the actual Promtail release, values, and log paths with the historical
   `vps/values/promtail.yaml`. Back up the configuration and each node's
   `/run/promtail/positions.yaml` securely; `/run` is volatile across node reboots.
   Verify Loki health, available disk and node log retention. Prepare a rollback using
   the actual old chart/version and values.
2. Stop Promtail and wait for termination **before** starting Alloy; overlapping both
   collectors can duplicate logs. For the historical release:
   `helm uninstall promtail -n monitoring --wait`. This removes the release, not the
   node's hostPath positions file. Allow for a collection gap during the cutover.
3. Install Alloy using the repository and pinned version above:
   `helm upgrade --install alloy grafana/alloy --version "$ALLOY_CHART_VERSION" -n monitoring -f vps/values/alloy.yaml --wait`.
   Alloy reads `/run/promtail/positions.yaml` only when its own positions do not exist;
   its new positions persist in node-local `/var/lib/alloy`. If Alloy has already run,
   investigate and back up its state before the cutover: an existing positions file
   takes precedence, so legacy positions will not be reimported automatically.
4. Check the Alloy rollout and logs, compare stream labels and recent entries in Loki,
   and verify both masking rules with **synthetic, non-secret** log lines. Check metrics,
   memory and the noisy-pod filter. Keep backups until recovery is verified.

Positions are offsets, not acknowledgements of delivery: shutdown, buffered batches,
rotation, missing files or a restart may still cause duplicates or missing lines.
If no valid legacy or Alloy positions exist, files are read from their beginning.
On failure, stop Alloy before restoring Promtail; Promtail cannot read Alloy's positions,
so restoring its old positions can replay or miss logs. Neither the installer nor this
procedure removes persistent log data automatically.

NetworkPolicies (`vps/manifests/network-policies.yaml`): Prometheus reaches every pod
(scrape targets, Alertmanager) and the node (Kubernetes API 6443, kubelet 10250,
node-exporter 9100), never the Internet; Grafana reaches its three datasources, the
Kubernetes API (dashboard sidecar) and HTTPS outside the cluster. Every pod of
`monitoring` only accepts connections from the namespace itself: Loki answers queries on
the logs of every namespace without authentication, so the applications never reach it.
The application namespaces let Prometheus in (default policy of `onboard-app.sh`). A policy
applies to new connections only: after changing one, restart the pods it selects before
testing.

Known items to review:
- cert-manager 1.21's documented Kubernetes support ends at 1.36; K3s 1.37 is not yet
  in its support matrix. Sealed Secrets CI also lists 1.33–1.36, and kube-state-metrics
  2.20 targets Kubernetes 1.36. Successful Helm rendering is not runtime support.
- On arm64 servers, the default `prometheus-config-reloader` v0.95.1 image does not exist:
  reuse the override of `local/values/prometheus.yaml`.

## Architecture diagram

```
                   ┌─────────────────────────────────┐
                   │            VPS (K3s)            │
                   │                                 │
  Pods (all NS) ───┼──► /var/log/pods/*.log ──┐      │
                   │                          │      │
                   │                          ▼      │
                   │                   ┌──────────┐  │
                   │                   │  Alloy   │  │
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
                   │   │ (Discord)           │       │
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
