# Syslog Server

**Status:** ACTIVE
**Version:** balabit/syslog-ng:latest
**Namespace:** logging
**Sync Wave:** 2
**Tags:** `logging` `infra`

---

## What it does
Centralized syslog receiver for all cluster nodes and infrastructure devices. Listens on TCP/UDP syslog ports, writes to a PVC, and the `log-archiver` CronJob archives those logs nightly to the NAS.

## How it works
Single-replica Deployment pinned to `k8smaster` (`nodeSelector: kubernetes.io/hostname: k8smaster`). Config is mounted from `syslog-server-configmap`. Logs are written to the `syslog-storage` PVC (mounted at `/var/log/remote`).

Two services:
- `syslog-ng` (ClusterIP) — internal cluster access on TCP 6514 / UDP 5514
- `syslog-ng-external` (NodePort, `externalTrafficPolicy: Local`) — external syslog on TCP 30514 / UDP 30515

## Config & dependencies
- `syslog-server-configmap` — syslog-ng.conf; edit and push to change parsing rules or file destinations
- `syslog-storage` PVC (namespace: logging) — log storage; also mounted by log-archiver
- `externalTrafficPolicy: Local` means the NodePort only works on k8smaster's IP (192.168.2.10)

## Access
- External syslog: tcp://192.168.2.10:30514, udp://192.168.2.10:30515
- Internal (cluster): syslog-ng.logging.svc:6514 / :5514

## Notes
Pinned to k8smaster because the log-archiver mounts the same PVC (`syslog-storage`) and both need to be on the same node when using `local-path` storage. If you move to `nfs-client` storage you can remove the nodeSelector.

Using `balabit/syslog-ng:latest` — consider pinning to a specific version for reproducibility.
