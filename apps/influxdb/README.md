# InfluxDB

**Status:** LIVE (ArgoCD app `influxdb`, auto-sync)
**Version:** `influxdb:2.7-alpine` (v2.7.12). Stays on 2.x: the Grafana datasource uses Flux, which 3.x does not have.
**Namespace:** monitoring
**Sync Wave:** 10
**Tags:** `observability` `storage`

---

## What it does
Time-series database for cluster and homelab metrics. Telegraf writes to it
(`apps/telegraf/`), Grafana reads from it (`apps/grafana/`).

## How it works
Single-replica StatefulSet pinned to `lane=infrastructure` (k8smaster). 25Gi
Longhorn PVC `influxdb-data`. The `DOCKER_INFLUXDB_INIT_*` settings in
`influxdb-configmap.yml` (org `pilab`, user `admin`, first bucket `telegraf`, 90d
retention) apply on first boot only. Changing them later does nothing.
Namespace `monitoring` is created by this app; grafana and telegraf reuse it.

## Secrets
SealedSecret `influxdb-auth` (`influxdb-sealed-secret.yml`), keys `admin-password`
and `admin-token`. Re-seal with the kubeseal flags in
`day0-infra-build/scripts/seal_secret.sh`.

## Access
- UI and API: https://influxdb.i3sec.com.au. LAN only (Traefik ingress, Let's
  Encrypt cert via `letsencrypt-prod`; Pi-hole resolves it to the Traefik VIP).
  Not in the Cloudflare tunnel list.
- In cluster: `http://influxdb.monitoring.svc.cluster.local:8086`.
- Log in as `admin` with the password from `influxdb-auth`.

## Org and buckets
Org `pilab`.
- `telegraf` (90d): cluster and platform metrics from Telegraf.
- `ai_metrics` (180d): LiteLLM metrics, route-validation and session-memory results
  (schema in `apps/telegraf/README.md`).
- `subscriptions`, `icloud_migration`: written by other jobs.

Only `telegraf` is created by the init config. Create other buckets with the
`influx` CLI inside the pod, for example
`influx bucket create -n NAME -o pilab -r 180d`. They live on the PVC, not in git.
Each writer gets its own token scoped to its bucket.

## Backup
The PVC is on Longhorn. There is no separate InfluxDB export job yet.
