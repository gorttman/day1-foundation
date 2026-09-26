# Telegraf

**Status:** LIVE
**Namespace:** monitoring
**Sync Wave:** 12 (after influxdb 10, grafana 11)
**Tags:** `observability` `telemetry`

## What it does
Collects cluster and platform metrics into InfluxDB. Grafana reads them
(dashboards "Cluster Overview" and "AI Platform", folder "Platform").

## Workloads
- `telegraf-node` (DaemonSet, both nodes): CPU, memory, swap, load, disk `/`,
  network, SoC temperature, and kubelet pod/node stats (`kubernetes_node`,
  `kubernetes_pod_container`). Bucket `telegraf`.
- `telegraf-platform` (Deployment): Prometheus scrapes of InfluxDB, ArgoCD
  (`argocd_app_info`), Longhorn, cert-manager. Bucket `telegraf`. Measurement
  `prometheus`, field = metric name, tag `service`.
- `telegraf-ai` (Deployment): scrapes LiteLLM `/metrics`. Bucket `ai_metrics`.
  Logs a DNS error every 30 s until LiteLLM exists (Stage 1). That is expected.

## Secret
`telegraf-influxdb` (SealedSecret), key `INFLUX_TOKEN`: an InfluxDB token with
write access to buckets `telegraf` and `ai_metrics` only. To rotate: create a new
token with `influx auth create`, re-seal (see `day0-infra-build/scripts/seal_secret.sh`
for the kubeseal flags), commit.

## Contracts for later build-plan stages
These are settings other stages must honour. They are written here so no stage
depends on remembering them.

**Stage 1 (LiteLLM):**
- Deploy as Service `litellm` in namespace `litellm`, port 4000. If the name
  differs, change `ai.conf` in `telegraf-config-cm.yml` and the namespace regex in
  the "AI platform pod memory" panel.
- Set `litellm_settings.callbacks: ["prometheus"]`.
- Set `require_auth_for_metrics_endpoint: false` (default is to require an API key;
  Telegraf has none). Safe because the Service is ClusterIP only.

**Stage 2 (route-validation CronJob)** writes line protocol to bucket
`ai_metrics`, measurement `route_validation`:
- tags: `check` = liveness | quality | qualification; `route`; `key`
- fields: `ok` (int 0/1), `latency_ms` (float), `score` (float 0-1)
It needs its own InfluxDB write token for `ai_metrics`.

**Stage 3 (session-memory sweep)** writes to bucket `ai_metrics`, measurement
`memory_distill`:
- tags: `outcome` = ok | error | skipped; `domain` = personal | enterprise
- fields: `duration_ms` (float), `pending_chats` (int)
It needs its own InfluxDB write token for `ai_metrics`.

The "AI Platform" dashboard already queries these names; a mismatch shows as an
empty panel.

## Notes
- Telegraf 1.40 removed `fieldpass`; use `fieldinclude`.
- InfluxDB stays on 2.7: the Grafana datasource uses Flux, which 3.x does not have.
