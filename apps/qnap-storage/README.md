# qnap-storage - static NFS PersistentVolumes on the QNAP

Media/library storage for apps, served from the QNAP (valinor-m)
`public_root` share (11T). One static PV per QNAP directory; each app
claims its slice with a PVC (`storageClassName: qnap-static` +
`volumeName`). kubelet mounts the NFS export on whichever node the pod
runs - storage follows the container, no host mounts involved.

| PV | QNAP path | Consumer |
|---|---|---|
| qnap-books | /public_root/books | kavita (ro) |

Planned as apps get their config pass: media (jellyfin + sonarr/radarr),
downloads (sabnzbd/jdownloader), paperless, immich, photos.

## Prerequisites (already in place)
- `qnap.i3sec.com.au` resolves to the wired face (192.168.1.30) on
  every node - managed by day0-infra-build `qnap_client` role
  (`--tags manage_qnap`). Pi-hole serves the WLAN face to normal
  clients; split view is deliberate.
- QNAP-side: the share's NFS host ACL must allow the node IPs, and the
  directory must be chowned 1000:1000 (apps run PUID/PGID 1000; the
  export does not root-squash, so chown works from any root mount).

## Rules
- **Never** put app *config* volumes (SQLite) here - NFS corrupts
  SQLite (pihole gravity.db incident). Only media/library content.
- Add new directories as separate PVs, ro where the app only reads.
- `capacity.storage` is informational for NFS - not enforced.
