# NFS Provisioner

**Status:** ACTIVE
**Version:** registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
**Namespace:** nfs-provisioner
**Sync Wave:** 1
**Tags:** `storage` `infra`

---

## What it does
Provides the `nfs-client` StorageClass so that PVCs with `storageClassName: nfs-client` are automatically provisioned as subdirectories on the NFS export at `192.168.1.10:/srv/nfs/syslog-store`.

## How it works
Single-replica Deployment running the upstream nfs-subdir-external-provisioner. It watches for PVC requests against the `k8s-sigs.io/nfs-subdir-external-provisioner` provisioner and creates a subdirectory per PVC on the NFS share. PVs are retained on delete (`reclaimPolicy: Retain`) and the directory is archived not deleted (`archiveOnDelete: true`).

## Config & dependencies
- NFS server: `192.168.1.10` (k8smaster host via nfs-server app, or the QNAP NAS — confirm which export is intended here)
- NFS export path: `/srv/nfs/syslog-store`
- Requires the NFS server to be up before PVCs are bound

## Notes
Wave 1 — first app to sync, since other apps may depend on NFS-backed PVCs.

Currently the provisioner is pointed at `/srv/nfs/syslog-store` specifically. If you add more storage classes in future, deploy a second instance with a different `PROVISIONER_NAME` and path rather than changing this one.
