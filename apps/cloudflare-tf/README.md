# cloudflare-tf

Manages Cloudflare zone + Zero Trust Tunnel config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job rather than from a laptop, CI, or
the dashboard. Two things, from one shared list of hostnames
(`tunneled_hostnames` in `variables.tf`):

- **The tunnel's Public Hostname / ingress config** (`tunnel.tf`) — which
  hostnames are exposed through the `cloudflared` tunnel, and what
  internal origin each forwards to. This used to be a dashboard-only,
  manually-clicked setting; it's now code.
- **A WAF custom rule enforcing mTLS** (`waf.tf`) on that same hostname
  set — blocks any request without a valid, non-revoked client cert.

Adding a new service to "Cloudflare-based secure access" is meant to be
exactly one change: add its hostname to `tunneled_hostnames`. Both the
tunnel route and the WAF protection follow from that one entry — see the
runbook below.

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

**TODO:** Brett's Mac cert still needs to be generated and added.

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

1. **Add the hostname** to `tunneled_hostnames` in `variables.tf`, no
   `origin` override needed:
   ```hcl
   default = {
     "argocd.i3sec.com.au" = {}
     "books.i3sec.com.au"  = {}
     "vscode.i3sec.com.au" = {}
     "newhost.i3sec.com.au" = {}
     "qnap.i3sec.com.au" = { origin = "https://192.168.2.30:443", no_tls_verify = true }
   }
   ```
   This one line does both jobs: adds the tunnel route *and* the mTLS
   WAF protection.

2. **The service needs its own public-facing Ingress** on
   `ingressClassName: nginx` (the `ingress-nginx-controller` this
   Terraform's default origin points at) — its existing internal
   ingress (if any) is almost certainly on `ingressClassName: traefik`
   and Cloudflare never reaches it. See
   `day2-services/apps/vscode-server/vscode-public-ingress.yml` for a
   worked example, including how to carry over app-level auth
   (`nginx.ingress.kubernetes.io/auth-url`, equivalent to a Traefik
   `forwardAuth` middleware) and a path-prefix rewrite (equivalent to a
   Traefik `stripPrefix` middleware) if the app needs either.

3. Commit and push both repos. Merging `day1-foundation`'s `main`
   applies the tunnel + WAF change for real immediately (`selfHeal` on
   both the root app-of-apps and this `Application`); the `day2-services`
   Ingress needs to be live too, or the tunnel will route to a host with
   nothing listening.

**Removing** a hostname: same step 1, minus the entry (plus whatever
cleanup the app's own public Ingress needs). No sealing involved for any
of this — the whole hostname/origin map is plaintext in git by design.

### Companion change: exposing `vscode.i3sec.com.au`

vscode-server was LAN-only (`ingressClassName: traefik`, `private-ca`
cert, no public DNS record at all — confirmed via a direct DNS query
against `1.1.1.1`, `NXDOMAIN`, versus `argocd`/`books`/`qnap` which all
resolve to Cloudflare's anycast IPs). Adding it to `tunneled_hostnames`
here is only half the change — `day2-services/apps/vscode-server/` also
gained `vscode-public-ingress.yml` and `vscode-public-auth-ingress.yml`,
mirroring the existing internal Ingress/Middleware setup but on
`ingressClassName: nginx`. Unlike `argocd-public-ingress.yml` (which
drops all local auth, relying solely on Cloudflare's edge mTLS),
vscode's app-level PAM auth is deliberately kept on the public path too
— defense in depth, since code-server is remote code execution, not a
read-only viewer. The `nginx.ingress.kubernetes.io/auth-url` annotation
replicates the internal Traefik `forwardAuth` middleware's call to the
same `/verify` endpoint.

One difference flagged as untested: Traefik's `redirectRegex` middleware
issues a browser redirect from `/gorttman` to `/gorttman/`; the nginx
`rewrite-target` equivalent just proxies a bare `/gorttman` request
straight through without changing the browser's address bar. If
code-server's frontend resolves assets relative to that address bar
path, this could break on the public path specifically even though the
internal path works fine. Verify once actually deployed.
