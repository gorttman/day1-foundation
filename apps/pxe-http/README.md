# PXE HTTP

**Status:** DEPRECATED 2026-09-03 - disabled, not deployed. The
Application is commented out of `apps/kustomization.yml`. Manifests kept
deliberately; see "Why it is deprecated" below before re-enabling.
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


---

## Why it is deprecated (2026-09-03)

This is one half of the PXE stack; `apps/dhcpd` was the other, disabled
the same day. Netboot has been dropped - nodes boot from local storage,
so nothing needs a bootloader hand-off any more.

Three things make it dead rather than merely unused:

1. **Nothing can reach it.** PXE requires DHCP to hand a client
   `next-server`/`filename`. With `dhcpd` disabled and the UDM not
   serving PXE options, no client is ever directed here.
2. **Its boot config is stale.** `pxe-http-configmap.yml` still passes
   `nfsroot=nfs.i3sec.com.au:/nfs/rootfs`, which is not a path the live
   NFS server exports.
3. **The boot path it serves was replaced.** The current golden-image
   pipeline is iSCSI/local-disk, built by `iscsi_netboot` in
   `day0-infra-build`, not netboot.

### Important: this does NOT make /srv/nfs/rpios/latest disposable

Kept separately and deliberately. That tree is still the **source
filesystem** the current golden image is built from -
`roles/iscsi_netboot/tasks/build_golden_image.yml` runs
`mksquashfs {{ nfs_os_path }}`, and `nfs_os_path` resolves to
`/srv/nfs/rpios/latest` (see `variables/play/day0_iscsi_prep.yml`).
Deleting it would break the ability to build a new golden image, and it
cannot be regenerated from code - `nfs_netboot`'s
`import_from_sd_card.yml` needs a physical SD card carrying a prepared
image. Do not treat it as netboot leftovers.

### If netboot is ever needed again

Re-enable `dhcpd` first (and re-derive its config - it is deprecated
too), fix the `nfsroot=` path in the ConfigMap to match what the NFS
server actually exports, and confirm the TFTP image still matches the
node hardware.
