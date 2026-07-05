# DHCPD

**Status:** ACTIVE
**Version:** built-in k3s dhcpd (image managed by dhcpd-conf repo)
**Namespace:** infra
**Sync Wave:** 5
**Tags:** `networking` `infra` `netboot`

---

## What it does
ISC DHCP server for the cluster network. Hands out leases to nodes and provides PXE boot parameters (`next-server`, `filename`) for netboot nodes.

## How it works
Uses two ArgoCD sources:
1. `day1-foundation` — Deployment, RBAC, ServiceAccount manifests
2. `dhcpd-conf` repo — raw `dhcpd.conf` config file

Kustomize builds a ConfigMap from `dhcpd.conf` which is mounted into the pod. When `dhcpd.conf` changes and is pushed to `dhcpd-conf`, ArgoCD detects drift and triggers a rollout automatically.

## Config & dependencies
- Edit `dhcpd-conf/dhcpd.conf` (separate repo) and push — ArgoCD resyncs and restarts the pod
- Depends on `infra` namespace existing (created by infra-namespace app)
- Works alongside `pxe-http` (wave 5) which serves the actual boot files

## Access
- DHCP: UDP 67/68 (hostNetwork — binds directly on the node)
- One instance per broadcast domain; for multiple VLANs use `dhcrelay`

## Notes
Runs with minimal capabilities and `hostNetwork` only. Do not run more than one dhcpd per broadcast domain or leases will conflict.
