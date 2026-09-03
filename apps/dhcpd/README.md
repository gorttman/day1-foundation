# DHCPD

**Status:** DEPRECATED 2026-09-03 - disabled, not deployed, do not
resurrect without re-deriving the config first. The Application is
commented out of `apps/kustomization.yml`. See "Why it is deprecated"
below and the header of `dhcpd.conf` in the `dhcpd-conf` repo.
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


---

## Why it is deprecated (2026-09-03)

Three independent reasons, each sufficient on its own:

1. **Netboot is gone.** This app existed to PXE-boot `pinode-01` over
   the backend VLAN. That boot path was dropped - the node boots from
   local storage. No TFTP server remains to serve the PXE options
   (verified: `tftpd-hpa` inactive, nothing on 69/udp), so they could
   not work even if dhcpd ran.
2. **The subnet no longer exists.** The config only ever declared
   `192.168.1.0/27`, the pre-VLAN20 backend. Since the 2026-08-30
   migration no node has an interface there, so `isc-dhcp-server`
   exited on every start with "No subnet declaration for end0
   (192.168.20.10) ... Not configured to listen on any interfaces!" -
   117 restarts before it was disabled.
3. **The UDM already serves DHCP** on every live network, including the
   reservations and DNS options this carried. Re-pointing this at
   `192.168.20.0/24` is NOT the fix - two DHCP servers on one segment
   is worse than none.

### The fault it left behind

It handed out `192.168.2.1` (gateway) and `1.1.1.1` as DNS, neither of
which resolves internal `*.i3sec.com.au` names. The failure is
deceptive: names with no public record (`jellyfin`) return NOERROR with
no A record, while names that have one (`books`, `immich`) return the
wrong public address. Corrected in the `dhcpd-conf` repo so a revival
cannot reintroduce it.

### If netboot is needed again

Re-derive the subnet, reservations and DNS from the live topology, and
resolve the two-DHCP-servers-on-one-segment question first. Do not just
uncomment the Application.
