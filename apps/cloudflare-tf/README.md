# cloudflare-tf

Manages Cloudflare zone + Zero Trust Tunnel config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job rather than from a laptop, CI, or
the dashboard. **Four** things, from one shared list of hostnames
(`tunneled_hostnames` in `variables.tf`) — see `HISTORY.md` for the full
story of how this list grew from two things to four, and everything that
went wrong building it:

- **The tunnel's Public Hostname / ingress config** (`tunnel.tf`,
  `cloudflare_zero_trust_tunnel_cloudflared_config`) — which hostnames
  are exposed through the `cloudflared` tunnel, and what internal origin
  each forwards to.
- **The public DNS record** (`tunnel.tf`, `cloudflare_dns_record`) — a
  proxied CNAME to `<tunnel_id>.cfargotunnel.com`. Separate resource
  from the tunnel config above; Cloudflare's dashboard wizard creates
  both atomically, Terraform doesn't.
- **A WAF custom rule enforcing mTLS** (`waf.tf`,
  `cloudflare_ruleset`) — blocks any request without a valid,
  non-revoked client cert.
- **The mTLS "Client Certificate" hostname list** (`waf.tf`,
  `cloudflare_certificate_authorities_hostname_associations`) — a third,
  separate setting that makes Cloudflare's edge actually *request* a
  client cert during the TLS handshake in the first place. Without a
  hostname here, the WAF rule above still blocks (no cert was ever
  presented) but the browser is never prompted at all — looks identical
  to a broken WAF rule from the outside.

Adding a new service to "Cloudflare-based secure access" is meant to be
exactly one change: add its hostname to `tunneled_hostnames`. All four
effects follow from that one entry — see the runbook below.

## Why this deviates from the dhcpd/coredns ConfigMap convention

Every other ConfigMap-from-files setup in this cluster
(`dhcpd-conf`, `dns-conf/coredns`) sets
`generatorOptions.disableNameSuffixHash: true`, so the generated
ConfigMap always has a fixed name. That's correct for them: those
ConfigMaps are mounted into long-running Deployments, and a stable name
means editing the config doesn't force an unrelated pod restart via a
changed volume reference — the app picks up the change through its own
reload mechanism (`reload 5s` in CoreDNS, a re-exec on the dhcpd side).

`cloudflare-tf-config` here does the opposite — **it lets Kustomize's
default content-hash suffix apply**. This ConfigMap is mounted into a
one-shot Argo CD **Sync hook** Job, not a long-running Deployment. The
hook only re-runs when its own pod template changes. If the ConfigMap
name stayed fixed, editing a `.tf` file would change the ConfigMap's
*contents* but not its *name*, so the Job spec (which references the
ConfigMap by name) would look identical to Argo CD, and it would never
re-fire the hook on a content-only change. Keeping the hash suffix means
every edit to a `.tf` file produces a new ConfigMap name, which changes
the Job spec, which is what makes Argo CD's sync (with `selfHeal`)
actually re-run Terraform.

In short: the other two disable the hash because they want a stable
reference; this one needs the hash because it wants change to be
visible to Argo CD.

## Terraform state backend: shared Postgres

State lives in the `pg` backend, in a dedicated `cloudflare_tf`
database/role on the same shared Postgres instance every other app on
this cluster uses (`day2-services/apps/postgres`), rather than NFS or
local `emptyDir` state. That instance already exists and this follows
its documented per-app onboarding pattern exactly (own login role, own
logical database) — see that repo's `postgres/README.md`.

`versions.tf` declares `backend "pg" {}` with no `conn_str` — that's
partial config on purpose, so the connection string (which embeds a
password) never lands in git. It's supplied at `terraform init` time via
`-backend-config`, reading `TF_BACKEND_PG_CONN_STR` from
`cloudflare-tf-secrets` (see `cloudflare-tf-job.yml`).

**Companion change in `day2-services`:** creating this backend meant
onboarding a new app database on the shared instance, so
`postgres-init-cm.yml`, `postgres-statefulset.yml`,
`postgres-sealed-secret.yml`, and that repo's README were all updated to
add the `cloudflare_tf` role/database — same three-step process already
documented there for `paperless`/`homeassistant`/`n8n`. The role and
database were also created directly on the running instance (via
`kubectl exec ... psql`), since `postgres-initdb` scripts only run once
against an empty data volume and won't re-run on the already-initialized
instance.

## Secrets

`cloudflare-tf-secrets` is a SealedSecret with four fields —
`TF_BACKEND_PG_CONN_STR`, `TF_VAR_zone_id`, `TF_VAR_cloudflare_api_token`,
`TF_VAR_allowed_client_cert_fingerprints` — all sealed for real against
this cluster's `sealed-secrets-controller` (namespace `kube-system`, the
kubeseal default). Nothing left to seal; this file is ready to commit and
sync.

**API token permissions required** (Zone-scoped, `i3sec.com.au`) — found
the hard way, one `Authentication error` at a time, so listing all of
them here up front for next time:
- Zone → **DNS** → Edit
- Zone → **SSL and Certificates** → Edit
- Zone → **Zone WAF** → Edit (or equivalent Firewall/Rulesets permission)
- Account → **Cloudflare Tunnel** → Edit

If a Job/diagnostic pod gets a `403 Authentication error` from the
Cloudflare API, check this list before assuming anything else is wrong —
it's almost always a missing permission, not a bug. Editing an existing
token's permissions doesn't change its value, so nothing needs
re-sealing when a new scope is added.

## Allow-listed client certs

`TF_VAR_allowed_client_cert_fingerprints` is a JSON array of SHA-256
fingerprints, read by Terraform via `cloudflare-tf-secrets`. It's sealed
(rather than a plain `default` in `variables.tf`, the way
`tunneled_hostnames` and `account_id` are) purely for tidiness/history —
a fingerprint isn't a credential: it's a one-way hash
of a public cert, and knowing it doesn't grant access to anything, so
there was never a strict secrecy requirement here. The table below is
the readable record of the same values; both copies exist on purpose and
should always match.

| device              | fingerprint (SHA-256)                                            |
|---------------------|-------------------------------------------------------------------|
| Brett's iPad        | `4070efa571840e48365bd2d56035c81aa7266935dc85df348d0711f75419ab1c` |
| Brett's iPad mini   | `489bef308d26147d202334f14b26ba8665caf4fc9e06e18634bf2026c7edacdb` |
| Brett's iPhone      | `9574ac73a0350b86ffa55536332ef41dda0e1b8bc88738fa688c29bb336ab266` |
| Marina's iPhone     | `fc0c591a682b9881dcada6bb1acf96d2b9909d2049cadbaef1e577983a056992` |
| Marina's iPad mini  | `45310e8704d0f266e7c7c685571df96c8c27846537074d15497cb8d3740563b5` |

**TODO:** Brett's Mac cert still needs to be generated and added. Checked
the cluster for any self-service tooling that might help — found
`day2-services/apps/ca-portal` (`ca.i3sec.com.au`), but that's a
different thing: it's for installing/trusting the internal **server**
TLS CA (`i3sec-private-ca`) on a device so internal HTTPS sites show a
green padlock, not for issuing an mTLS **client** certificate. There's
no cluster-side mechanism for the latter — the other 5 certs must have
come from whatever Cloudflare-side flow was used originally (Zero
Trust → mTLS Certificates, or WARP device enrollment). Once the Mac has
a cert, adding it here is just the runbook below — get its fingerprint,
add a row, reseal.

### Runbook: adding, removing, or rotating a device cert

1. **Get the new cert's fingerprint** (safe to paste anywhere — not a
   secret):
   ```bash
   openssl x509 -in device.crt -noout -fingerprint -sha256 \
     | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
   ```
   If you only have a `.p12`/`.pfx`, extract the cert first:
   ```bash
   openssl pkcs12 -in device.p12 -clcerts -nokeys -out /tmp/device.crt
   # then run the openssl x509 command above against /tmp/device.crt, then rm it
   ```

2. **Update the table above** — add/remove/edit the row for that device.

3. **Rebuild the full JSON array** from every row currently in the table
   (adding a device = append its fingerprint; removing one = drop its
   fingerprint; rotating = swap the value in place), e.g.:
   ```
   ["fingerprint1","fingerprint2",...]
   ```

4. **Seal it**, replacing only the one field (this does not disturb
   `TF_BACKEND_PG_CONN_STR`, `TF_VAR_zone_id`, or
   `TF_VAR_cloudflare_api_token`):
   ```bash
   echo -n '["fingerprint1","fingerprint2",...]' \
     | sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --raw \
         --scope strict --namespace infra --name cloudflare-tf-secrets
   ```
   (kubeseal defaults to controller `sealed-secrets-controller` in
   `kube-system`, which matches this cluster — no extra flags needed.)

5. **Paste the output** into `cloudflare-tf-sealedsecret.yml`, replacing
   the existing `TF_VAR_allowed_client_cert_fingerprints` value only.

6. Commit and push. Note: if this lands on `main`, it applies
   immediately — the root app-of-apps and this app's `Application` both
   have `automated: {selfHeal: true}`, so a merge triggers a real
   `terraform apply` against the live Cloudflare zone, not just a review
   diff.

## Tunnel ingress: `tunneled_hostnames`

`tunnel.tf` manages `cloudflare_zero_trust_tunnel_cloudflared_config` —
the tunnel's Public Hostname list, previously a dashboard-only setting.
It, and the WAF rule's protected-hostname list (`local.mtls_protected_hostnames`
in `waf.tf`), are both derived from one variable:

```hcl
variable "tunneled_hostnames" {
  type = map(object({
    origin        = optional(string, "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80")
    no_tls_verify = optional(bool, false)
  }))
}
```

For anything running in this cluster, the origin is always the same —
Cloudflare forwards to the shared `ingress-nginx-controller` by Host
header, and `ingress-nginx` does the final per-app routing via that
app's own Ingress object. That's why the default needs no per-host
input: a k8s-hosted service only ever needs its hostname added, nothing
else. `qnap.i3sec.com.au` is the one real exception — a physical NAS,
not a k8s Service — so it overrides `origin` to point straight at
`https://192.168.2.30:443` (with `no_tls_verify = true`, since NAS web
UIs commonly run a vendor/self-signed cert; unconfirmed, drop it if
qnap's cert turns out to be valid).

The tunnel's ingress config is a **full-list replacement** on every
apply, not additive — `tunnel.tf` always writes every entry in
`tunneled_hostnames` plus a required trailing catch-all
(`http_status:404`). There's no partial-update risk as long as this file
stays the single source of truth; just don't hand-edit Public Hostnames
in the dashboard afterward, or the next `selfHeal` sync will silently
revert that change back to whatever's in git.

`var.cloudflare_tunnel_id` is the UUID of the existing token-based tunnel
(Zero Trust > Networks > Tunnels) — set directly as a plain `default` in
`variables.tf`, same treatment as `account_id`. Not a secret, just an
identifier: knowing it grants no access without the API token too, and
it's realistically write-once, so it doesn't get the sealed-secret
round-trip.

### Runbook: exposing a new k8s-hosted service through the tunnel

This is the full procedure, including every gotcha `vscode` actually hit
(see `HISTORY.md` for the blow-by-blow). Follow all of it, not just step
1 — most of these apps have their own login, and that's where the real
landmines are.

1. **Add the hostname** to `tunneled_hostnames` in `variables.tf`, no
   `origin` override needed for anything that's a normal k8s Service
   behind `ingress-nginx`:
   ```hcl
   default = {
     "argocd.i3sec.com.au" = {}
     "books.i3sec.com.au"  = {}
     "vscode.i3sec.com.au" = {}
     "newhost.i3sec.com.au" = {}
     "qnap.i3sec.com.au" = { origin = "https://192.168.2.30:443", no_tls_verify = true }
   }
   ```
   This one line drives all four effects (tunnel route, DNS record, WAF
   protection, mTLS cert-request setting).

2. **Give the service a public-facing `ingressClassName: nginx` Ingress**
   — its existing internal ingress (if any) is almost certainly on
   `ingressClassName: traefik`, which Cloudflare's tunnel never reaches
   for the default origin. Use `vscode-public-ingress.yml` in
   `day2-services/apps/vscode-server/` as the template. Keep the
   internal Ingress/Middleware setup completely untouched — this is a
   second, parallel Ingress object for the same host, not a replacement.

3. **If the app has its own login/auth** (most of these do — the
   decision made early in this project was every app keeps its own auth,
   not just Cloudflare's mTLS gate), and that auth currently works via a
   Traefik `forwardAuth` Middleware internally, **check what its
   "not authenticated" response looks like** before assuming the nginx
   annotations alone will work:
   - If it returns **`401`**: straightforward. Add
     `nginx.ingress.kubernetes.io/auth-url` (pointing at the same
     internal auth-check service Traefik already uses) and
     `nginx.ingress.kubernetes.io/auth-signin` (nginx builds its own
     redirect to a login URL on seeing `401` — don't rely on anything
     the auth check itself returns for this).
   - If it returns **`302`** (a redirect Traefik passes straight
     through): **this will produce a `500`, not a redirect,** on the
     nginx path. nginx's `auth_request` module only accepts `2xx`/
     `401`/`403` from the auth subrequest — a `302` is treated as an
     internal error. This isn't a config tweak, it's a real
     incompatibility between the two ingress controllers' forward-auth
     models. The auth service itself needs to return `401` (with an
     HTML body containing a client-side meta-refresh/JS redirect, so
     Traefik's pass-through behavior still produces a working redirect
     internally) — see `images/vscode-auth/auth_server.py` in
     `day2-services` for the exact pattern, and check for the same
     Safari-WebSocket-caused design reasoning before touching it.
   - **Whatever the login page's own path is** (e.g. `/app/auth`), make
     sure the auth-required Ingress's path pattern doesn't also match
     it. A regex path like `/app(/|$)(.*)` matches `/app/auth` too, and
     nginx's location matching **prefers a matching regex location over
     a matching plain-prefix one, regardless of which is more
     specific** — so the login page ends up behind its own auth check,
     creating an infinite redirect loop that eventually 414s. Exclude it
     explicitly: `/app(?!/auth(?:/|$))(/|$)(.*)` (non-capturing lookahead,
     so it doesn't shift `$1`/`$2` if you're also using
     `rewrite-target`).

4. **Commit and push both repos** (`day2-services` first if a new
   Ingress was needed, so the route exists before the tunnel starts
   sending traffic there; then `day1-foundation`). Both repos'
   Applications have `automated: {selfHeal: true}` — merging to `main`
   applies for real immediately, no separate "sync" step.

5. **If Argo CD seems to be re-running the old config**, it's probably
   sync lag, not a bad merge — check
   `kubectl get application -n argocd cloudflare-tf -o
   jsonpath='{.status.sync.revision}'` against the actual latest commit
   SHA. If they don't match, force it:
   ```bash
   kubectl patch application -n argocd cloudflare-tf --type merge \
     -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
   ```
   If that alone doesn't produce a new Job (true for Sync hooks
   specifically — they don't participate in normal drift detection),
   trigger an explicit sync:
   ```bash
   kubectl patch application -n argocd cloudflare-tf --type merge \
     -p '{"operation":{"sync":{"revision":"<commit-sha>","prune":true}}}'
   ```

6. **If this is the very first time Terraform has managed a hostname
   that already existed manually** (migrating something in, rather than
   a genuinely brand-new service), expect an "already exists" error on
   the first `apply` for whichever resource(s) predate Terraform (WAF
   ruleset is one-per-zone-per-phase; DNS records and the mTLS hostname
   list can also already have entries). Fix with `terraform import`
   *before* applying — see `HISTORY.md` #6/#7/#11 for worked examples of
   each resource type's import ID format (none of them are consistent
   with each other, check the resource's actual docs).

**Removing** a hostname: same step 1, minus the entry, plus deleting
whatever public Ingress was added for it in step 2. No sealing involved
for any of this — the whole hostname/origin map is plaintext in git by
design.

## WARP client access (SSH to k8smaster)

`warp.tf` lets `gorttman@i3sec.com.au` and `brett@i3sec.com.au` (only —
`var.warp_authorized_emails`) SSH to k8smaster (`192.168.2.10`) from
anywhere, by enrolling a device in Cloudflare WARP. Three resources:

- `cloudflare_zero_trust_tunnel_cloudflared_route` — private network route
  for `192.168.2.10/32` over the existing tunnel, so the address is
  reachable through it at all.
- `cloudflare_zero_trust_device_default_profile` — the account's one
  WARP device policy, switched from its stock split-tunnel mode
  (`exclude` everything private, i.e. `192.168.0.0/16` and friends) to
  `include` mode listing only `192.168.2.10/32`. **`include` and
  `exclude` are mutually exclusive on this resource** — the API rejects
  a request setting both, so this isn't "add one include entry
  alongside the existing excludes," it's a full mode switch: with WARP
  on, only traffic to k8smaster goes through Cloudflare, everything else
  (normal browsing, etc.) bypasses WARP entirely. That's a deliberate
  trade for simplicity — carving a single `/32` out of the
  `192.168.0.0/16` exclude under `exclude` mode instead would need ~16
  explicit complement CIDRs, and this account has no other Zero Trust
  use case (no Gateway filtering, no other Access app) that
  `include`-mode's "everything else bypasses WARP" side effect could
  break. If that ever changes, revisit this trade-off.
- `cloudflare_zero_trust_access_application` (`type = "warp"`) — gates
  device *enrollment* to `var.warp_authorized_emails`. The account's
  only identity provider is `onetimepin` (email OTP, no domain
  restriction) — without this Access app, anyone who can receive an
  email at an address they type in could enroll a device and see this
  same split-tunnel config.

**One-time import required** before the first apply: the device default
profile is a singleton that already existed on the account before this
Terraform did (every account has exactly one). Same pattern as the WAF
ruleset in HISTORY.md #6 — creating it fresh would collide with the
existing one.
```bash
terraform import cloudflare_zero_trust_device_default_profile.this '<account_id>'
```
(`account_id` = `var.account_id`'s value, not a secret — see
`variables.tf`.) The tunnel route and the Access app are both brand new,
no import needed for either.

**Client-side enrollment** (manual, once per device, same treatment as
the client certs above — nothing to codify here):
1. Install the Cloudflare One (WARP) app.
2. Team domain: `i3sec`.
3. Log in with an authorized email; complete the OTP.
4. SSH to `192.168.2.10` exactly as on the LAN — same key, same command.
   WARP only supplies the network path when off-LAN; it adds no new
   auth layer of its own.
