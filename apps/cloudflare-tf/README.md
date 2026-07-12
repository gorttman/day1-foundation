# cloudflare-tf

Manages Cloudflare zone config (currently: one WAF custom rule enforcing
mTLS on `argocd`/`books`/`qnap`) as Terraform, applied in-cluster by an
Argo CD Sync-hook Job rather than from a laptop or external CI.

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

`cloudflare-tf-secrets` is a SealedSecret with three fields —
`TF_BACKEND_PG_CONN_STR`, `TF_VAR_zone_id`, `TF_VAR_cloudflare_api_token`
— all sealed for real against this cluster's `sealed-secrets-controller`
(namespace `kube-system`, the kubeseal default). Nothing left to seal;
this file is ready to commit and sync.
