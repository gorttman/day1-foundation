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
| qnap-immich | /immich | apps/immich (day2, 2026-08-04) - immich-server (rw), RWO not RWX, root:users 2775 |
| qnap-paperless | /paperless/media | apps/paperless (day2, 2026-08-08) - paperless-media (rw), RWO not RWX |
| qnap-pihole-live | /pihole | apps/pihole (day2, 2026-08-13) - pihole-data (rw), RWO not RWX, root:root |
| qnap-calibre-web-live | /calibre-web | apps/calibre-web (day2, 2026-08-13) - calibre-web-config-backup (rw), RWO not RWX, root:root |

Planned as apps get their config pass: media (jellyfin + sonarr/radarr),
photos (the general Drive-photos migration, distinct from Immich's own
`/immich` library).

## pihole/calibre-web: off the backup disk, onto the main pool (2026-08-13)

qnap-pihole and qnap-calibre-web-backup both pointed at subdirectories
of `/backup` - the USB backup disk itself, not the QNAP's main storage
pool every other PV here uses. That meant their only copy of data sat
inside the one directory tree day0-infra-build's QNAP snapshot job
deliberately excludes (it can't back up the backup disk into itself),
so neither had any generational history, and worse, neither had any
protection if the backup disk itself ever failed - the opposite of what
the whole backup project exists for.

Fix: new `/pihole` and `/calibre-web` exports created on the main pool
(day0-infra-build's `qnap_main_pool_dirs` role for the directories,
`qnap_exports`'s `create_export.yml` for the NFS registration - the
first time this project created a brand-new export rather than just
modifying an existing one's squash setting, see that role's own
comments for why it needed a QNAP Shared Folder in `smb.conf`, not just
an `nfssetting` entry). Both are now also in `qnap_snapshot_sources`, so
they get the same 7/4/13 generational history as books/vault/immich/
paperless/inbox/media.

Sequencing: qnap-pihole-live and qnap-calibre-web-live were created
alongside the old PVs, not in place of them - data was copied and
verified from the old `active_backup/` locations before either PVC was
repointed. Once both apps were confirmed serving real data from the new
PVs, the old qnap-pihole/qnap-calibre-web-backup PVs and their backing
`active_backup/pihole` and `active_backup/calibre-web` directories were
retired - see day0-infra-build's `qnap_backup_directories.yml` history
if reconstructing the old state is ever needed.

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
  clients; split view is deliberate. **Caveat as of 2026-07-19:**
  confirmed correct on k8smaster, not confirmed on diskless netboot
  nodes (pinode-01 etc, whose `/etc/hosts` is a separately-synced
  overlay) - see the qnap-vault IP-pin note below for why `qnap-vault`
  now sidesteps this entirely rather than relying on it.
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

## qnap-vault pinned to the management IP, not the FQDN (2026-07-19)

`qnap-vault`'s `nfs.server` was `qnap.i3sec.com.au` (same as every other
PV here) until this. Investigating an apparent WLAN-vs-management-network
mismatch turned up real NFSv4 trunking behaviour, not a misconfiguration:
on k8smaster, `mount`/`/proc/mounts` displays the mount source as
`192.168.2.30:/vault` (the WLAN face Pi-hole serves), but the live
established TCP session and the `addr=` mount option both confirm the
actual RPC traffic already lands on `192.168.1.30` (the wired/management
face) regardless - the server-address discovery baked into NFSv4 session
setup silently corrects for it after the initial hostname resolution.

That's fine on k8smaster, where the `qnap_client` role's `/etc/hosts` pin
is confirmed present. It's an open question on `pinode-01` (this PV's
actual consumer, since `obsidian` runs there) - a diskless netboot node
whose `/etc/hosts` is a separately-synced per-node overlay with no
confirmed-live check behind it, the same class of "the mechanism should
have run but nobody's verified it actually did" gap this project has
already hit more than once (see the sealed-secrets backup history in
day0-infra-build's `rebuild-gap-audit.md`, item 2).

Rather than trust the overlay, `qnap-vault-pv.yml`'s `nfs.server` is now
the literal `192.168.1.30`. Confirmed after the change, directly on
pinode-01 (`ssh -i ~/.ssh/pinode_cluster_ed25519 pinode-01`, checking
`/proc/mounts`): the kubelet-managed mount now reads `192.168.1.30:/vault/obsidian`
with no DNS/hosts step involved at all. `nfs.server` is an immutable PV
spec field, so this required the same delete-PV/PVC-and-let-ArgoCD-recreate
dance as the original QNAP migration - no data was at risk (`Retain`
policy, same underlying export, no content actually moved this time).

Scoped to `qnap-vault` only. `qnap-books` and the rest still use the FQDN
form and haven't shown any problem doing so (their consumers - calibre-web,
books-pipeline - may or may not run on diskless nodes at any given
schedule; worth the same IP-pin treatment if one ever turns out to,
but not applied speculatively here).

## downloads directories (2026-07-21)

`arr-stack` (day2-services) needs `/downloads` (confirmed via
`showmount -e qnap.i3sec.com.au` - a real, distinct top-level export,
previously unused: empty, `root:root`, no PV declared anywhere). Same
multi-consumer situation as `/inbox`/`/books` above - SABnzbd and
LazyLibrarian are containers in arr-stack's own single shared pod, not
separate PVC consumers - so this follows the established pattern for
that case: a raw pod-level `nfs:` volume in `arr-stack-deployment.yml`
(day2-services), no PV/PVC here, rather than forcing the one-PV-per-
directory rule onto a case it doesn't fit.

Created and chowned `1000:1000` (arr-stack's own PUID/PGID convention -
**not** the `1000:100`/"users" convention `books-pipeline`/`calibre-web`
use; the two app groups don't share a UID scheme, deliberately not
unified here):
- `/downloads/complete` - SABnzbd's general (non-books) completed-download
  directory
- `/downloads/incomplete` - SABnzbd's in-progress downloads

No `/downloads/complete/books` subdirectory - the `books` SABnzbd
category's completed-directory is configured to be `books-pipeline`'s
own `import/` mount directly (a separate NFS export, `/books`, mounted
read-write with `subPath: import` in the same pod), so a books download
lands in the exact place `books-pipeline` already scans - zero extra
hops, no sweep/copy step in between.

## `/books` root permission regression (2026-08-01)

Found live, after a multi-day QNAP outage that needed a physical power
cycle to recover from: the `/books` export **root directory itself**
had reverted to `root:users` `755` (no group-write), while every
subdirectory underneath it remained correctly owned `books-pipeline:users`.
`calibredb add`'s own startup does a case-sensitivity probe by writing
a throwaway file directly into the library root (`calibre_test_case_sensitivity.txt`)
before anything else runs - with the root non-writable by the
`books-pipeline` container's UID (1000, group `users`), **every single
`calibredb add` call failed outright**, and `books_pipeline.py`'s
`promote()` correctly quarantined each one with the real
`PermissionError` as the reason (working as designed - a legitimate,
informative quarantine, not silent data loss).

Scale found: 19,902 of 51,860 total quarantine entries (38%) carried
this exact reason - almost certainly present since well before this
specific outage, not something the outage itself caused (that many
files couldn't have accumulated in the outage's short window alone).
The QNAP crash/reboot is the best available explanation for *when* the
root's permissions last changed, but the underlying fragility - a
single directory's mode gating the entire pipeline's ability to add
anything, with no monitoring on it - predates this incident.

Fixed with `chmod 2775 /books` (setgid, matching every subdirectory's
own `drwxr-sr-x` convention, done via a root-privileged one-off pod -
this NFS export does not enforce `root_squash`, confirmed live).
Recovered all 19,902 falsely-quarantined files by moving them back
from `quarantine/` into `import/` (matching filename, reason sidecar
removed) for a normal pipeline re-run - `promote()` always recomputes
the library path from the file's own embedded metadata regardless of
source location, so this was safe to do in bulk without preserving any
of quarantine's own folder structure.

If `calibredb add` ever starts failing on this same
`PermissionError: .../calibre_test_case_sensitivity.txt` pattern
again, check `/books`'s own root permissions first (`ls -ld /books`)
before assuming a code-level bug - this exact regression is one hard
NAS reboot away from recurring, and there's no automated check for it
yet.

## paperless directory (2026-08-01)

`paperless` (day2-services) needed a consumer folder both `inbox-router`
and the Paperless-ngx webserver can reach - same multi-consumer
situation as `/inbox`/`/books`/`/downloads` above, so it follows the
same pattern: a raw pod-level `nfs:` volume in both
`inbox-router-cronjob.yml` and `paperless-deployment.yml` (the latter
via `subPath: consume`), no PV/PVC.

`/paperless` was already a real, distinct top-level export (confirmed
via `showmount -e qnap.i3sec.com.au`, alongside `/photos`, `/media`,
`/immich`, `/cold` - all still unused/unplanned) - empty, `root:root`,
no directories under it. Created `/paperless/consume`, chowned
`root:users` (GID 100), mode `2775` - same setgid convention as
`/books`'s post-2026-08-01 fix, applied from the start here rather than
discovered the hard way a second time.

Paperless's own container runs its actual process as root (confirmed
live via `kubectl exec ... id`, not the `paperless` user its `/etc/passwd`
defines) and self-chmods its mounted volumes to `777` on boot regardless
of host-side ownership - so the `root:users 2775` directory permissions
here matter for `inbox-router` (which writes as UID 1000/GID 100, not
root) but aren't load-bearing for Paperless's own read/consume/delete
side of this directory.

The original `paperless-consume` PVC (`nfs-client` StorageClass) was
confirmed empty before being removed in favour of this export - no data
migration needed. `paperless-data` and `paperless-media` are still on
`nfs-client` (the same "wrong home" pattern already fixed for Obsidian's
vault - real data on k8smaster's local-disk export instead of the QNAP)
- not addressed here, flagged for a later pass since it's out of scope
for a consumer-folder wiring change and neither volume is multi-writer.

While wiring this up, hit the **exact same root-permission regression**
`/books` had (above) on a second export: `/inbox`'s own root was
`root:users 755` (no group-write, no setgid) even though every
subdirectory under it (`books`, `quarantine`, `triage`) was correctly
`2775`. This blocked creating the new `inbox/records` explicit-dir
source as UID 1000/GID 100 (inbox-router's own identity). Fixed the
same way: `chmod 2775 /inbox` plus creating `/inbox/records` with the
same ownership. Two independent export roots hitting the identical
regression means this is a pattern, not a one-off - **worth checking
`ls -ld` on every QNAP export root** (`/books`, `/inbox`, `/paperless`,
...) if a similarly-shaped failure shows up again, not just the one
that already bit us.

Also found live: Paperless's own container re-chowns whatever it finds
under its mounted volumes to its own UID (1000) on every boot
(`[init-folders] Running with root privileges, adjusting directories
and permissions` in its startup log) - so the `root:users` ownership
set here doesn't survive a Paperless restart, only the `2775` mode
does. Functionally fine since inbox-router also runs as UID 1000 (so
owner-match covers it), but worth knowing if group-based reasoning
about this directory's permissions stops making sense later.

## paperless-media migrated to the QNAP (2026-08-08)

The "wrong home" gap flagged above (`paperless-media` on `nfs-client`,
k8smaster's own local-disk export, not the QNAP) got fixed - real
financial/legal documents, found during a backup-coverage audit to have
*zero* backup mechanism of any kind, not even a same-disk one. Same fix
Obsidian's vault already got: migrate to a QNAP-backed static PV.

Created `/paperless/media` as a sibling of the existing `consume/`
directory (not nested inside it - `consume/`'s own mount uses
`subPath: consume`, so `media/` sitting alongside it at the export root
never lands inside Paperless's watched consume directory). Chowned
`1000:1000`, mode `2775`, matching `consume/`'s ownership - though per
the note above, Paperless's own boot-time chown means this doesn't
strictly matter long-term, kept for consistency rather than necessity.

Existing content (176 files, 19M) copied via `rsync -av` from the old
`nfs-client`-backed PV's real path
(`/srv/nfs/syslog-store/paperless-paperless-media-pvc-...`) to
`/paperless/media` *before* the PVC was repointed, verified by matching
file count and total size on both sides - same sequencing the Obsidian
migration used, so there was never a window where the data existed in
neither place. `paperless-data` (cache/index, not primary documents,
and separately covered by the Postgres backup for anything that
actually matters) stays on `nfs-client` - not migrated, not worth it.

## immich directory (2026-08-04)

`/immich` was already a real, distinct top-level export (confirmed
alongside `/photos`/`/media`/`/cold` back on 2026-08-01 - see the
paperless directory note above - unused until now). Chowned
`root:users` (GID 100), mode `2775` from the start - same convention
as `/paperless`, applied up front rather than discovered the hard way
a second/third time.

Unlike Paperless, `immich-server`'s own container runs as root by
default (confirmed live: `id` inside the image returns
`uid=0(root) gid=0(root)`, no PUID/PGID mechanism, no
non-root-by-default behavior to account for) - so the `root:users`
ownership here is really just documentation of intent; root can write
regardless (`no_root_squash`, same as every other export), and there's
no non-root container UID that needs the group-write bit the way
inbox-router's UID 1000 did on `/inbox`/`/books`.

## pihole and calibre-web-backup migrated to the QNAP (2026-08-10)

Both were on `nfs-client` (k8smaster's own local disk) - the same
"wrong home" pattern already fixed for Obsidian, Immich, and Paperless.
Unlike those, neither of these lives under its own top-level QNAP
export - both sit under `/backup/active_backup/`, the same staging area
`postgres-backup` already uses (see day2-services `apps/postgres`
README), since they're also disaster-recovery-shaped data rather than
primary application content with its own natural home.

`pihole-data` turned out to be more than its name suggests - not just
the `gravity-backup.db` safety copy, but pihole's entire persistent
config (`setupVars.conf`, custom/adlists, `dhcp.leases`, dnsmasq confs).
Checked before assuming otherwise (`du`/`find` against the live PVC's
underlying nfs-client directory) rather than taking the "backup" name
at face value.

Both apps' backup-writing sidecars (`gravity-backup`, `config-backup`)
are plain `busybox` containers with no `securityContext` - confirmed
live via `grep` against each deployment, not assumed - so both run as
literal root. QNAP-side directories (`active_backup/pihole`,
`active_backup/calibre-web`) chowned `0:0` to match, via
day0-infra-build's `qnap_backup_dirs` role. This match actually matters
now: `/backup` is `no_root_squash` (see `qnap_exports`), so a
mismatched owner genuinely blocks the write - not theoretical, this
exact class of bug had just bitten `postgres-backup` hours earlier the
same day when its export's squash mode changed under it.

Existing content copied via `rsync` and verified by file count + size
match before either PVC was repointed: pihole 19 files/7.7M,
calibre-web 2 files/884K. Both apps confirmed serving their real
pre-migration data afterward (pihole's restored config visible via
`kubectl exec ... ls /etc/pihole`, calibre-web's restored `app.db`/
`client_secrets.json` visible via `kubectl exec ... ls /config`) - not
just "the PVC bound successfully."

One operational wrinkle worth recording: pausing an individual app's
ArgoCD `Application.spec.syncPolicy.automated` didn't hold for
`pihole`/`calibre-web` the way it did for the earlier Paperless
migration - `day2-services` (the app-of-apps parent) was actively
re-asserting each child Application's syncPolicy back from git within
seconds, fighting the imperative `kubectl scale --replicas=0` needed to
release the old PVC. Pausing the *parent* Application's own
`syncPolicy.automated` alongside the two children resolved it. Worth
checking for this same fight on any future PVC swap under this
app-of-apps structure, rather than assuming the Paperless migration's
approach will always hold.
