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
| qnap-books | /books | calibre-web (rw) - was kavita (ro) until 2026-07-17 |
| qnap-vault | /vault/obsidian | obsidian (rw), RWO not RWX - see obsidian directories note below |

Planned as apps get their config pass: media (jellyfin + sonarr/radarr),
downloads (sabnzbd/jdownloader), paperless, immich, photos.

## Handing a static PV from one app to another

Happened for real the first time on 2026-07-17 (kavita → calibre-web,
see `day2-services/apps/calibre-web/README.md` and homelab-book chapter
002 for the full story) - worth recording as a general procedure since
every PV here has `persistentVolumeReclaimPolicy: Retain`, and this
will happen again.

Deleting the old app's PVC does **not** make the PV `Available` for a
new claim - `Retain` means exactly what it says. The PV goes to
`Released`, still carrying a `claimRef` pointing at the now-deleted
PVC. A new PVC targeting the same PV by `volumeName` sits in `Pending`
against that stale reference indefinitely - looks identical to a
permissions or export problem in `kubectl describe pvc` until you
check `kubectl get pv <name> -o yaml` and notice `status.phase:
Released` with a `claimRef` still attached. Clear it with:

```
kubectl patch pv <name> --type merge -p '{"spec":{"claimRef": null}}'
```

One further wrinkle if the old app is being removed via Argo CD rather
than just having its PVC deleted directly: confirm the old app's PVC
(and everything else) is *actually* gone, not just orphaned. Deleting
an Argo CD `Application` object only cascades into deleting its managed
resources if that `Application` carries the
`resources-finalizer.argocd.argoproj.io` finalizer - without it,
removing the `Application` from a parent app-of-apps just orphans
everything underneath, silently still running. `kubectl get pvc -A |
grep <old-pvc-name>` before attempting the claimRef patch is the way to
catch this - patching the PV while the "deleted" app's PVC is still
technically live and bound just fails silently (nothing changes,
because the PV isn't actually free yet).

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

## obsidian directory (2026-07-18)

`obsidian` (day2-services) previously ran its vault PVC on the `nfs-client`
StorageClass, which - not obvious from the name - is backed by k8smaster's
own local-disk NFS export (`192.168.1.10:/srv/nfs/syslog-store`, meant for
syslog archival). Wrong home under the general rule this repo already
follows: data belongs on the QNAP, only genuinely cluster-internal state
belongs on k8smaster's own disk. Moved to `qnap-vault` (`/vault/obsidian`)
as the first real application of that rule - see homelab-book for the
fuller writeup once it exists.

Created `/vault/obsidian` and copied the existing (32K, just the seeded
`.obsidian/` config, no real notes yet) vault content across before
switching the PVC over, so the vault's init container's seed-if-missing
check no-ops on first boot against the new volume instead of re-seeding.

Unlike every other PV here, this one is RWO, not RWX - obsidian is
single-replica with no multi-writer use case, so claiming RWX would just
be a wider grant than the workload needs. The old local-disk PV
(`pvc-fd0d8910-...`) was left `Released` rather than deleted; the stale
copy under `/srv/nfs/syslog-store/` can be cleaned up manually once the
QNAP copy has proven stable for a while.

## pdf-triage directory (2026-07-17)

`pdf-triage` (day2-services, prompt 6) needs `/inbox/triage` - the
inbox-router routes undeclared bare-root PDFs here (its `routes.yaml`
`pdf-to-triage` rule), since a bare PDF is ambiguous between books and
Paperless. Created and chowned `10001:10001`. Failures quarantine to
the existing `/inbox/quarantine`, not a new location - a triage failure
means "couldn't confidently classify," which is a general failure, not
a books-specific one, so it belongs with inbox-router's quarantine, not
books-pipeline's.

## inbox/books ownership standardized to root:users, 2775 (2026-07-18)

`/inbox`, `/inbox/books`, `/inbox/quarantine`, `/inbox/triage`, `/books`,
`/books/import`, `/books/library`, `/books/library/{books,comics}`, and
`/books/quarantine` were all originally chowned `10001:10001` (an
invented UID/GID that matched nothing else, chosen only so
`inbox-router`/`books-pipeline`/`calibre-web` agreed with each other).

Re-standardized after hitting the same failure twice in one session:
a human (gorttman) copying files in directly - a real ~43,000-file
personal library, dropped straight into `/books/import` - changed
`/mnt/books`'s root ownership to their own login, silently locking out
the `10001`-owned containers' write access. Exclusive single-UID
ownership doesn't survive a human touching the export directly, which
was always going to happen on a shared home NAS.

Fixed by switching to **`root:users` (GID 100), mode `2775`** on all of
the directories above:
- `root` ownership is free to write regardless (every export here has
  `no_root_squash`), so this isn't giving anything up compared to the
  old scheme.
- `100`/`users` is gorttman's own real supplementary group on this
  host (confirmed via `id`/`getent group`) - not invented, and already
  the group ownership the user's own bulk copy happened to land with.
- The setgid bit (`2`, not just `775`) is the actual fix for the
  recurring failure: any new file or directory created under these
  paths - by a human's `cp`/`rsync`, or by a container - automatically
  inherits group `users`, rather than group ownership depending on
  whichever UID happened to create it.
- `inbox-router` and `books-pipeline` were rebuilt (`v0.2.0`) to run as
  UID `1000` / GID `100` instead of the invented `10001:10001`, matching
  this and the pre-existing day0/day1 convention (every linuxserver-based
  app in this cluster already runs `PUID=1000`) at the same time -
  see `day2-services/images/{inbox-router,books-pipeline}/Dockerfile`.

Scoped to `inbox`/`books` only - the other QNAP exports (photos, media,
paperless, etc.) have their own existing schemes, untouched here.
Rolling this convention out further is a separate decision, not implied
by this change.
