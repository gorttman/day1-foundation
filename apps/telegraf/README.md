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

## RBAC note
`telegraf-kubelet-stats` grants `get` on `nodes/stats`, `nodes/metrics` and
`nodes/proxy`. The kubelet maps its `/pods` endpoint to `nodes/proxy`, and the
Telegraf `kubernetes` input calls `/pods` first: without it the input fails with
403 and emits no pod metrics at all. `nodes/proxy` is broader than stats-only
(it can reach other kubelet endpoints); accepted here because the agent is a
trusted image on a single-user cluster.

## Longhorn scraping
Each Longhorn manager pod reports only its own node's storage and the volumes it
manages, so scraping the `longhorn-backend` Service saw one node at a time (Telegraf
keeps one connection open, so it stuck to a single manager). `telegraf-platform`
now discovers the manager pods by label (`app=longhorn-manager`, namespace
`longhorn-system`) and scrapes each one. That needs the `telegraf-pod-discovery`
ClusterRole (get/list/watch pods) bound to the `telegraf` ServiceAccount, which the
Deployment now runs as. It must be cluster-scoped: Telegraf's pod watcher lists pods
cluster-wide and filters by namespace itself, so a namespaced Role gets 403. (The
kustomization's `namespace: monitoring` would also have moved a Role out of
`longhorn-system`.) The agent already had `nodes/proxy`, which can read every pod on a
node, so this adds little exposure.

## Contracts for later build-plan stages
These are settings other stages must honour. They are written here so no stage
depends on remembering them.

**Stage 1 (LiteLLM): done 2026-09-27.** LiteLLM runs as Service `litellm` in namespace
`litellm`, port 4000 (`day2-services/apps/litellm`), with the Prometheus callback on and
`require_auth_for_metrics_endpoint: false` (ClusterIP only). If the Service name or
namespace ever changes, change `conf/ai.conf` and the namespace regex in the "AI platform
pod memory" panel. LiteLLM reports `+Inf` for keys and users with no budget; the
Starlark processor in `conf/ai.conf` drops non-finite values before the write.

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

## Config rolls the pods
The three `.conf` files under `conf/` are turned into a ConfigMap with a content hash in
its name (`configMapGenerator` in `kustomization.yml`). Editing a `.conf` therefore
changes the pod specs and rolls the pods; Telegraf does not reload its config itself.
