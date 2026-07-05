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

## Storage - RAM data dir + NFS backups (pihole pattern)
RAM emptyDir data dir (SQLite inside) + hourly tar backups on the
`grafana-data-backup` nfs-client PVC, restored on pod start - the
pihole/kavita pattern, so the pod floats freely between nodes. Worst
case after an unclean node death: up to 1h of dashboard edits lost.
The provisioned datasource is a ConfigMap and never at risk.
