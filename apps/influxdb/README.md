# InfluxDB

**Status:** BACKLOG (commented out in apps/kustomization.yml — not yet deployed)
**Version:** not pinned (image tag not set in manifests — must pin before deploying)
**Namespace:** monitoring
**Sync Wave:** 10
**Tags:** `observability` `storage` `backlog`

---

## What it does
Time-series database for storing metrics from the cluster and homelab. Intended as the storage backend for an observability stack (Telegraf → InfluxDB → Grafana).

## How it works
StatefulSet with PVC, ingress, and a ConfigMap for initial config. Secret holds credentials. Namespace `monitoring` created via `CreateNamespace=true` in the ArgoCD Application.

## Config & dependencies
- Secret `influxdb-secret` must exist before deploy (seal with `scripts/seal_secret.sh`)
- Ingress assumes a working ingress-nginx controller
- PVC will use the default StorageClass unless overridden

## Access
- Ingress-based (URL depends on ingress config in the manifests)
- Default admin credentials: stored in sealed secret

## Notes
**Before enabling:** pin the image tag in `influxdb-statefulset.yml` — current manifests have no explicit tag which risks unexpected upgrades.

**To enable:** uncomment `- influxdb/influxdb-app.yml` in `apps/kustomization.yml`, ensure the sealed secret is present, and push.
