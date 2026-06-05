# NFS Server

**Status:** ACTIVE
**Version:** gists/nfs-server:latest
**Namespace:** infra
**Sync Wave:** 6
**Tags:** `storage` `infra` `netboot`

---

## What it does
In-cluster NFS server that exports `/srv/nfs` to all clients. Primary consumers are the PXE/netboot flow (RPi OS root filesystems) and the nfs-provisioner StorageClass.

## How it works
Single-replica Deployment with `hostNetwork: true` and `privileged: true`. Pinned to the control-plane node (`arm64` + `control-plane` node affinity). On startup the entrypoint script:
1. Creates `/srv/nfs` if missing
2. Writes `/etc/exports` (single wildcard export)
3. Runs `exportfs -ra`, then starts `rpcbind`, `rpc.nfsd`, and `rpc.mountd --foreground`

Storage is a `hostPath` volume at `/srv/nfs` on k8smaster — data persists across pod restarts as long as the node is up.

## Config & dependencies
- `nfs-exports` ConfigMap defines the export list (currently not mounted by the deployment — export is hardcoded in entrypoint). The ConfigMap is kept as a reference/docs artifact.
- No PVC — uses hostPath `/srv/nfs` directly
- Ports: 2049 (TCP/UDP), 111 (TCP/UDP) — exposed via hostNetwork

## Access
- NFS clients mount: `192.168.2.10:/srv/nfs` (or subpaths like `/srv/nfs/rpios/latest`)

## Notes
`privileged: true` is required for the kernel NFS daemon. The NFS server runs wave 6 (after dhcpd wave 5) since it serves the netboot images that nodes try to fetch at DHCP time.

The ConfigMap (`nfs-exports`) is not currently mounted into the pod — the export is written inline in the entrypoint command. If you want to manage exports declaratively, wire up the ConfigMap as a volume and adjust the entrypoint to read from it.
