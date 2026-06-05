# PXE HTTP

**Status:** ACTIVE
**Version:** nginx:1.25-alpine (HTTP) + ghcr.io/gorttman/tftp:latest (TFTP)
**Namespace:** infra
**Sync Wave:** 5
**Tags:** `netboot` `infra`

---

## What it does
Serves netboot files to RPi5 nodes over TFTP (initial bootloader hand-off) and HTTP (kernel, initrd, OS root). Together with dhcpd, this is the full PXE stack for diskless/netboot nodes.

## How it works
Single Pod with two containers sharing a `hostPath` volume (`/var/www/html/netboot/rpi5`):

- **nginx** container — serves files over HTTP on port 8081, path `/netboot/rpi5/`
- **tftp** sidecar — binds to `eth0` IP on UDP 69, serves from `/tftpboot` (same hostPath)

Both use `hostNetwork: true` so TFTP and HTTP are reachable on the node IP directly. The TFTP sidecar detects `eth0`'s IP at startup and binds explicitly to it.

## Config & dependencies
- `pxe-http-config.yml` / `pxe-http-configmap.yml` — nginx config (check manifests for details)
- Netboot files must be pre-staged to `/var/www/html/netboot/rpi5` on k8smaster before nodes try to boot
- Depends on dhcpd pointing nodes at this server's IP for `next-server` / `filename`

## Access
- HTTP: http://192.168.2.10:8081/netboot/rpi5/
- TFTP: tftp://192.168.2.10/ (UDP 69)

## Notes
`hostNetwork: true` is required for TFTP to work — TFTP uses ephemeral UDP ports for data transfer that don't work cleanly through kube-proxy NAT. The TFTP image is a custom build (`ghcr.io/gorttman/tftp:latest`) — pin this tag if stability is needed.

File staging is handled by the `day0-infra-build` Ansible automation, not this app.
