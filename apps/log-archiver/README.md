# Log Archiver

**Status:** ACTIVE
**Version:** alpine:latest (CronJob container)
**Namespace:** logging
**Sync Wave:** 3
**Tags:** `logging` `infra` `cron`

---

## What it does
Nightly CronJob that archives logs collected by syslog-ng to the NAS (valinor-m) via NFS. Runs at 02:00 daily and retains the last 3 successful and 3 failed job records.

## How it works
1. CronJob fires at 02:00, spins up an Alpine container with `hostNetwork: true`
2. Mounts the `syslog-storage` PVC (same PVC used by syslog-ng) at `/var/log/remote`
3. Runs `/scripts/archive-logs.sh` from the ConfigMap
4. Connects to NAS via NFS — Wake-on-LAN is used to wake the NAS if it's sleeping (requires `NAS_MAC_ADDRESS` in secret)
5. Copies logs older than `ARCHIVE_DAYS` to the NAS export path, then prunes local copies

## Config & dependencies
- `log-archiver-secret` (SealedSecret): `NAS_MAC_ADDRESS`, `NAS_IP_ADDRESS`, `NFS_EXPORT_PATH`, `ARCHIVE_DAYS`
- `log-archiver-configmap`: contains `archive-logs.sh` script
- Depends on `syslog-storage` PVC existing (created by syslog-server app)
- Depends on NAS being reachable at `NAS_IP_ADDRESS` over NFS

## Notes
`hostNetwork: true` and `privileged: true` are required for WoL (raw socket) and NFS mount inside the container.

The job runs independently of whether syslog-ng is running — it just operates on whatever files are in the PVC.
