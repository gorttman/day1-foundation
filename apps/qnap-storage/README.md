# qnap-storage - static NFS PersistentVolumes on the QNAP

Media/library storage for apps, served from the QNAP (valinor-m). One
static PV per QNAP directory; each app claims its slice with a PVC
(`storageClassName: qnap-static` + `volumeName`). kubelet mounts the
NFS export on whichever node the pod runs - storage follows the
container, no host mounts involved.

Export paths are bare top-level names (`/books`, `/photos`, ...), not
`/public_root/<name>` - confirmed via `showmount -e qnap.i3sec.com.au`
and a real test mount (2026-07-14). qnap-books originally used
`/public_root/books`; that stopped resolving at some point after the
PV was created; the existing kernel-level mount kept the pod looking
healthy on a stale cached handle while every actual read was failing.
Fixed 2026-07-14 - see day0-infra-build's `qnap_client` role for the
equivalent host-level mounts, which is where the wrong path was
originally caught.

| PV | QNAP path | Consumer |
|---|---|---|
| qnap-books | /books | kavita (ro) |

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

## inbox-router directories (2026-07-16)

`inbox-router` (day2-services, prompt 2 of the inbox-router series)
needs write access to `/inbox` and `/books`, not read-only - it
doesn't fit the one-PV-per-directory/ro-consumer pattern above, so it
mounts these two exports directly via a pod-level `nfs:` volume in
its own CronJob (no PV/PVC), rather than adding a second static PV
alongside `qnap-books`. A static PV binds 1:1 to a single PVC, and
`qnap-books` is already bound to kavita's - a second consumer needing
the same export has to go around that layer, not through it.

Created and chowned `10001:10001` (the inbox-router image's non-root
UID/GID) on 2026-07-16:
- `/inbox/books` - explicit-dir source for bulk book uploads
- `/inbox/quarantine` - router's quarantine sidecar location
- `/books/import` - router's write destination for the books route

Also re-chowned the `/inbox` and `/books` export roots themselves
from `root:root` to `10001:10001` (mode unchanged at `755`), so the
non-root container can create further subdirectories under them
later without another manual step. `/books`'s "already chowned
1000:1000" prerequisite above turned out not to hold in practice -
it was actually `root:root` - but it didn't break kavita since `755`
already grants read to everyone regardless of owner.

## books-pipeline directories (2026-07-17)

`books-pipeline` (day2-services, prompt 4) needs its own subdirectories
under `/books`, alongside the `import/` created above - `library/` is
not a separate QNAP export (confirmed against the full export list in
day0-infra-build's `qnap_client` role: only `/books` exists at the top
level), it's a subdirectory of `/books` like everything else here.
Created and chowned `10001:10001`:
- `/books/library` - promoted-book root
- `/books/library/books` - EPUB/PDF library
- `/books/library/comics` - CBZ/CBR library, routed here unconditionally
  by format, never on content judgment
- `/books/quarantine` - books-pipeline's own quarantine (distinct from
  `/inbox/quarantine` above - that one's inbox-router's, this one's
  books-pipeline's, different pipeline stage)

## pdf-triage directory (2026-07-17)

`pdf-triage` (day2-services, prompt 6) needs `/inbox/triage` - the
inbox-router routes undeclared bare-root PDFs here (its `routes.yaml`
`pdf-to-triage` rule), since a bare PDF is ambiguous between books and
Paperless. Created and chowned `10001:10001`. Failures quarantine to
the existing `/inbox/quarantine`, not a new location - a triage failure
means "couldn't confidently classify," which is a general failure, not
a books-specific one, so it belongs with inbox-router's quarantine, not
books-pipeline's.
