# Grafana

Visualization for the observability stack at https://grafana.i3sec.com.au
(internal-only, private-ca TLS via Traefik). Namespace `monitoring`,
shared with influxdb.

- First login: `admin` / `admin` (Grafana forces a password change).
- The **InfluxDB data source is pre-provisioned** (Flux,
  org/bucket/token from the `grafana-influxdb` SealedSecret, pointing at
  `influxdb.monitoring.svc:8086`) - it appears ready-wired on first login.
  The token is the InfluxDB admin token; scope it down in a config pass
  if desired.

## Deliberately unconfigured (install-only)
- No dashboards, no panels
- No alert rules / notification channels
- No extra data sources

## Storage - PLACEHOLDER
2Gi `local-path` PVC (holds Grafana's internal SQLite DB): node-local,
non-durable - same caveat as the day2 apps. The deployment targets
`lane=infrastructure` (k8smaster), the only node whose local-path is
real disk. Move to proper storage later; never put the SQLite volume
directly on NFS.
