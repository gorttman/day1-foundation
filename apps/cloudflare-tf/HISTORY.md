# cloudflare-tf: build history, mistakes, and fixes

Full narrative of building this app, for institutional memory. If
something looks weird in the code, the answer is probably in here.

## The goal

Bring Cloudflare Zero Trust config that already existed as manual
dashboard clicks (a WAF rule enforcing mTLS on a few self-hosted apps,
plus the tunnel's Public Hostname routing) under Terraform, run in-cluster
by an Argo CD Sync-hook Job. End state: exposing a new service through
Cloudflare should be "add a hostname to a variable," not a sequence of
dashboard screens.

## What it took to get there

### 1. ConfigMap convention deviation (by design, not a mistake)

Every other ConfigMap-from-files setup in this cluster
(`dhcpd-conf`, `dns-conf/coredns`) sets `disableNameSuffixHash: true` for
a stable name, because they feed long-running Deployments that reload
their own config. This app deliberately does the opposite — keeps
Kustomize's default hash suffix — because the ConfigMap feeds a one-shot
Argo CD Sync hook Job, and the hook only re-fires when its own pod spec
changes. A stable ConfigMap name would mean editing a `.tf` file changed
the ConfigMap's contents but not the Job's spec, and Argo would never
notice. See the README for the full reasoning.

### 2. vscode: back-and-forth on how to expose it

Early mistake: assumed vscode's public path had to go through
`ingress-nginx` the same way argocd/books do, and built a whole parallel
nginx-based Ingress + auth setup from scratch. Got corrected: the actual
ask was "treat it exactly like every other app on the tunnel" (i.e. yes,
the standard `ingress-nginx` path, not a special case) — a real
back-and-forth caused by not asking early enough what "treated the same"
actually meant. Ended up, correctly, building a proper `ingress-nginx`
Ingress for vscode (`vscode-public-ingress.yml` /
`vscode-public-auth-ingress.yml` in `day2-services`), matching the
existing `books`/kavita pattern, keeping vscode's own PAM auth as
defense-in-depth alongside the Cloudflare-edge mTLS gate (explicit
decision: every app keeps its own auth, no exceptions).

### 3. NFS-backed emptyDir breaks Terraform's state lock

First real Job failure: `terraform init` failed immediately with
`Error acquiring the state lock: ... no locks available`. Root cause:
this node's default `emptyDir` is NFS-backed with `local_lock=none`, and
NFS's advisory locking is disabled on that mount, so any `flock()` call
fails with `ENOLCK`. Terraform needs a real file lock for state locking
even when using the `pg` backend. Confirmed empirically with two
throwaway test pods on the same node (`flock` fails on default
`emptyDir`, succeeds with `medium: Memory`). Fix: `tf-workspace`'s
`emptyDir` uses `medium: Memory` (tmpfs) in `cloudflare-tf-job.yml`. Same
underlying issue as an earlier Pi-hole/SQLite incident on this cluster.

### 4. tmpfs sizeLimit too small

Second failure, after the above fix: `no space left on device` while
*installing* the Cloudflare provider binary. The provider alone is
~228Mi (confirmed via a local `terraform init`) — the initial `64Mi`
sizeLimit was a guess that didn't account for that. Bumped to `512Mi`.

### 5. Argo CD sync lag, repeatedly

Multiple times, pushing a fix to `main` didn't make the Job re-run with
the new manifest — Argo CD's Application stayed synced to the *previous*
commit until its next git-polling cycle, so retrying just reran the old,
already-broken config. Worked around each time with:
```bash
kubectl patch application -n argocd cloudflare-tf --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
# and, when a refresh alone didn't trigger a new sync (hooks don't
# participate in normal drift detection the way regular resources do):
kubectl patch application -n argocd cloudflare-tf --type merge \
  -p '{"operation":{"sync":{"revision":"<commit-sha>","prune":true}}}'
```
Also learned: Sync-hook pods get cleaned up (per `hook-delete-policy`)
fast enough that watching via Argo's own retry loop can miss the chance
to read logs. Running the exact same command manually in a throwaway
pod (same image, same ConfigMap, same secret) sidesteps this entirely
and lets you watch synchronously.

### 6. WAF ruleset collided with a pre-existing manual one

Once the Job actually ran, `terraform apply` failed:
`exceeded maximum number of zone rulesets for phase
http_request_firewall_custom` — Cloudflare allows only one custom
ruleset per phase per zone, and one already existed (`name: "default"`,
`last_updated: 2026-07-09` — the mTLS rule that was created manually
before this whole project started, i.e. the very thing this project
exists to codify). Fix: `terraform import` to adopt the existing
ruleset by ID before applying. One real side effect: because the
imported ruleset's `name` differs from ours, Terraform treats renaming
it as forcing a replace (destroy-then-create), so there was a genuine
~1 second gap with no WAF rule active during that one cutover.

### 7. DNS records are a separate resource from tunnel ingress

`argocd`/`books`/`qnap` already had public DNS records (auto-created
by the dashboard's "Public Hostname" wizard when they were originally
set up manually) — but that wizard does two things atomically: it adds
the tunnel ingress rule *and* creates the DNS record. Terraform's
provider models these as two unrelated resources
(`cloudflare_zero_trust_tunnel_cloudflared_config` for ingress,
`cloudflare_dns_record` for DNS) — nothing does both. Since our
Terraform only ever wrote the first, vscode's ingress rule went live but
it had no DNS record, so it wasn't reachable at all from outside. Fixed
by adding `cloudflare_dns_record` (type `CNAME`, content
`${tunnel_id}.cfargotunnel.com`, proxied), importing the 3 existing
records, letting Terraform create the missing one for vscode.

### 8. Security incident: token briefly exposed in this session

A diagnostic `curl -v` call echoed the full `Authorization: Bearer
<token>` header into command output during troubleshooting. Caught and
flagged immediately; recommended rotating the Cloudflare API token as a
precaution. Lesson: never use verbose curl output with a real
`Authorization` header present — redirect stderr away or strip the
header from any debug output before it's ever printed.

### 9. API token permission gaps, twice

The Cloudflare API token was scoped only for what was assumed necessary
up front (Zone WAF Rulesets, Tunnel config). Hit `Authentication error`
(403) on:
- the DNS records endpoint (needed **Zone → DNS → Edit**)
- the Client Certificate hostname-associations endpoint (needed
  **Zone → SSL and Certificates → Edit**)

Both were existing-token permission edits (no new token, no re-sealing
needed) — but each one was only discovered by hitting the wall, not
anticipated. Lesson: when a project touches N different Cloudflare API
surfaces, check required permissions for all of them up front rather
than one at a time.

### 10. Found and cleaned up an unrelated broken config: k8smaster

While reading the live mTLS Client Certificate hostname list to confirm
our plan wouldn't clobber anything, `k8smaster.i3sec.com.au` turned up —
completely unknown to our Terraform, left over from an earlier, separate
attempt (outside this project) at browser-based SSH access via the same
tunnel. A sweep across DNS records, tunnel ingress, the mTLS hostname
list, and Cloudflare Access Applications found:
- a DNS record (CNAME to the tunnel)
- **no** tunnel ingress rule (already gone, apparently by accident, from
  an earlier Terraform apply that never listed it)
- still present in the mTLS Client Certificate hostname list
- a Cloudflare Access Application named "k8smaster" with **`"policies":
  []`** — an empty policy list, which lines up exactly with the
  symptom that started the whole side-quest ("wants email confirmation
  and never sends it" — an Access app with no policy has nothing telling
  it who's allowed in).

Confirmed with the user this was "all wrong config" and should be
removed entirely, not migrated in. Deleted the Access Application and
the DNS record directly (neither was ever Terraform-managed); the
Terraform-managed mTLS hostname list correctly dropped it on the next
apply, simply by never including it in `tunneled_hostnames`.

### 11. The mTLS "Hosts" list is a *third* separate setting

Believed (from the original project brief) that the SSL/TLS → Client
Certificates hostname list "has no Terraform resource, stays manual."
That was wrong — outdated information, not re-verified. The resource
`cloudflare_certificate_authorities_hostname_associations` exists. This
setting matters because it's what makes Cloudflare's edge *request* a
client certificate during the TLS handshake at all, before the WAF rule
(which only *checks* whether a cert was presented) ever runs. Without a
hostname in this list, a browser is never prompted for a cert and the
WAF rule just always blocks — which looks identical to a broken WAF rule
from the outside, but isn't. vscode was missing from this list even
after the WAF rule and tunnel were both correct. Added the resource,
imported the existing list, applied — now covers all four hostnames.

### 12. vscode's 404 → 500 → 414 progression

Once DNS, tunnel routing, WAF, and the mTLS hosts list were all
correct, vscode still didn't work — in stages:
- **404**: actually stale negative DNS caching on Pi-hole (the zone's
  SOA negative-cache TTL is 1800s) from before the record existed.
  Fixed with `pihole restartdns`.
- **403 with no prompt**: expected — the WAF rule correctly blocking a
  request with no client cert (confirmed by reproducing the identical
  403 against `argocd.i3sec.com.au`, a known-working host, with no cert).
- **500**: the real bug. `auth_server.py`'s `/verify` endpoint returns
  `302` (with a `Location` header) when unauthenticated — which
  Traefik's `forwardAuth` middleware passes straight through to the
  browser (hence internal access worked fine), but nginx's
  `auth_request` module only accepts `2xx`/`401`/`403` from the auth
  subrequest; anything else, including `302`, is treated as an internal
  error. Confirmed via `ingress-nginx-controller`'s own logs:
  `auth request unexpected status: 302`. Fixed by changing `/verify` to
  return `401` with an HTML body containing a client-side (meta-refresh
  + JS) redirect — Traefik still passes this through unaltered so the
  internal path is unaffected, and nginx's `auth-signin` annotation
  builds its own redirect on seeing `401`. Verified this didn't reopen
  the original reason the code used a redirect instead of Basic-Auth
  (Safari not resending Basic-Auth credentials on a WebSocket upgrade) —
  that was already fixed by the existing cookie-session approach, and
  only affects the very first unauthenticated page load, never a
  WebSocket request.
- **414 Request-URI Too Large**: a second, genuine bug introduced by the
  401 fix. `vscode-public-ingress.yml`'s auth-required path regex
  (`/gorttman(/|$)(.*)`) also matched `/gorttman/auth` — the login page's
  *own* path, served by a separate, non-auth-required Ingress
  (`vscode-public-auth`). nginx's location-matching rules mean a
  matching regex location always wins over a matching plain-prefix
  location, even when the prefix is more specific — so the login page
  itself was being sent through the same auth check, creating an
  infinite loop (401 → redirect to login → login page hits the same
  auth check → 401 again → redirect, nesting the URL deeper each hop)
  until nginx rejected the ever-growing URL outright. Fixed with a
  negative lookahead (`/gorttman(?!/auth(?:/|$))(/|$)(.*)`) excluding the
  login path from the auth-required regex.

## What's true now

One variable (`tunneled_hostnames` in `variables.tf`) drives four
Terraform resources:

1. `cloudflare_zero_trust_tunnel_cloudflared_config` — tunnel routing
2. `cloudflare_dns_record` — the public DNS entry
3. `cloudflare_ruleset` (WAF) — mTLS enforcement (cert must be
   presented, verified, non-revoked, and optionally fingerprint-pinned)
4. `cloudflare_certificate_authorities_hostname_associations` — makes
   Cloudflare's edge actually request a cert for that hostname at all

Adding a hostname to that one map, for anything that's a standard
k8s-hosted app behind `ingress-nginx`, now genuinely produces all four
effects from one line. See the README's runbook for the full procedure,
including the nginx-specific gotchas from #12 above that the next app
with its own login page will probably also hit.

## Lessons for next time

- **This cluster's default `emptyDir` doesn't support POSIX file
  locking** (NFS-backed, `local_lock=none`). Anything that needs local
  file locks (Terraform state operations, SQLite, similar) needs
  `medium: Memory`.
- **Argo CD's git polling can lag noticeably.** When testing a fix that
  needs to land *now*, force it: hard-refresh the Application, and if
  that alone doesn't trigger a new sync (true for Sync-hook resources,
  which don't participate in normal drift detection), patch
  `.operation.sync` directly with the target revision.
- **Cloudflare's dashboard wizards routinely do more than one thing
  atomically.** Before assuming a single Terraform resource replicates a
  dashboard workflow, check whether the wizard secretly also touches DNS,
  a separate TLS/cert setting, an Access Application, etc. This project
  hit three separate "the dashboard did this for you" surprises (DNS
  records, the mTLS hostname list, and — as a red herring — a Cloudflare
  Access Application from an unrelated older project).
- **Check API token permissions for every Cloudflare API surface the
  project touches, up front**, not one `Authentication error` at a time.
- **nginx's `auth_request` and Traefik's `forwardAuth` are not
  drop-in-compatible** for an existing auth service. `auth_request` only
  accepts `2xx`/`401`/`403`; anything else (including a `302`, which
  Traefik handles fine) is an internal error. If porting an existing
  Traefik-based forward-auth setup to also work behind `ingress-nginx`,
  expect to need changes on the auth service's side, not just ingress
  annotations.
- **Overlapping regex + prefix paths on the same nginx Ingress host are
  dangerous.** nginx's location matching prefers a matching regex
  location over a plain prefix location regardless of which is more
  specific. Any auth-required catch-all regex needs to explicitly
  exclude sibling paths (like a login page) that must not go through the
  same auth check.
- **`terraform import` is required, every time, for anything the
  dashboard created before Terraform existed.** Check for pre-existing
  resources (rulesets, DNS records, hostname lists) before writing
  "create" logic, or the first `apply` will fail with a conflict.
- **Never run verbose HTTP debugging (`curl -v`) with real
  `Authorization` headers present** — it echoes the header value into
  output that may get logged or persisted.
