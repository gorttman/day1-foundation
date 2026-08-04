# unifi-tf

Manages the UniFi Dream Machine's config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job — the same pattern
`apps/cloudflare-tf` uses, applied to the household network instead of
the Cloudflare edge. Scope is "everything that can be" managed as code:
networks/VLANs, WLANs, per-device radio/physical settings, firewall,
port forwards, static routes, static DHCP reservations, user groups.

**Status:** credential sealed, app registered, **zero `unifi_*` resources
yet** — this is stage 2 of the rollout (scaffold with zero resources,
confirm the Job runs `init`/`plan`/`apply` cleanly end to end) once both
this app's PR and the Postgres-onboarding PR are merged. The Postgres PR
must merge first (or at the same time) — `terraform init` against the
`pg` backend will fail if the `unifi_tf` role/database doesn't exist yet.

## Why this deviates from cloudflare-tf's risk profile

`cloudflare-tf` manages Cloudflare's edge — worst case on a bad apply is
a routing/WAF misconfiguration affecting public access to self-hosted
services. This app manages the live gateway and access points for the
whole house: a bad apply on a network or WLAN resource can drop Wi-Fi
for every device, and UniFi provisioning changes cause a real AP/gateway
reprovision (a brief but real outage), not just a config reload.

That's why this app is built up in stages rather than landing "the whole
UniFi config as Terraform" in one PR:

1. Inventory the Dream Machine's actual current config via its API —
   every resource written here has to match what's *actually live*
   first, never authored from guesswork.
2. Scaffold with zero resources, confirm the Job runs `init`/`plan`/
   `apply` cleanly end to end.
3. One resource type at a time — networks first (everything else refers
   to them), then WLANs, then per-device radio settings, then firewall,
   then port forwards/static routes, then static clients — each
   `terraform import`ed against the existing object, never created
   fresh, and each its own commit/PR so a bad stage is easy to isolate
   and revert.

Do the first-ever apply of each new resource type at a low-usage time —
even a no-op-intended change can trigger a brief AP reprovision.

## Credential — sealed (2026-08-04)

Network application version confirmed at 10.5.67 (the version that
matters for API-key eligibility — not the UDM/UniFi-OS version, which
is a separate number; see HISTORY.md #3), well above the 9.0.108
minimum. API key created from **Integrations → Create New API Key**
inside the local Network application UI (not Site Manager — see
HISTORY.md #3 for why that distinction matters), no expiry set (see
HISTORY.md #3 on rotation). Sealed into `unifi-tf-secrets` alongside
`TF_BACKEND_PG_CONN_STR`, same `kubeseal --raw` pattern as
`cloudflare-tf-secrets`.

### Runbook: rotating the API key later

1. Integrations page → revoke the old key, create a new one, copy it
   immediately (shown once).
2. Seal just that field, leaving `TF_BACKEND_PG_CONN_STR` untouched:
   ```bash
   echo -n '<new-key>' \
     | sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --raw \
         --scope strict --namespace infra --name unifi-tf-secrets
   ```
3. Paste the output into `unifi-tf-sealedsecret.yml`, replacing only the
   `TF_VAR_unifi_api_key` value.
4. Commit and push — lands on `main` with `automated: {selfHeal: true}`,
   so it applies on merge like everything else here.

## Provider: `filipowm/unifi`, not `paultyng/unifi`

`paultyng/unifi` is the better-known UniFi Terraform provider, but its
docs cap out at controller v6.x support and password-only auth.
`filipowm/unifi` is an actively maintained fork with explicit UDM/UDM-Pro/UCG
support, API-key auth, and much broader resource coverage — networks,
WLANs, both the legacy (`firewall_group`/`firewall_rule`) and newer
zone-based (`firewall_zone`/`firewall_zone_policy`) firewall models,
port forwards, static routes, DNS records, static clients (`unifi_user`),
user groups, RADIUS, and per-device settings including radios
(`unifi_device` — channel, TX power, channel width, minimum-RSSI/roaming
threshold, LED behavior).

API-key auth is preferred for the same reason `cloudflare-tf` uses a
scoped API token rather than full account credentials: it's revocable
and doesn't require storing a real admin password.

## State backend: shared Postgres

Same pattern as `cloudflare_tf`: a dedicated `unifi_tf`
database/role on the shared Postgres instance
(`day2-services/apps/postgres`), onboarded via that app's automated
init-Job path (the README there recommends this over manual `kubectl
exec` for any new database going forward). `versions.tf` declares
`backend "pg" {}` with no `conn_str` — partial config on purpose, so the
connection string never lands in git; supplied at `terraform init` time
via `-backend-config`, reading `TF_BACKEND_PG_CONN_STR` from
`unifi-tf-secrets`.

## Scope

**Managed**, in rollout order:

- **Networks/VLANs** (`unifi_network`) — base layer, everything else
  refers to these.
- **WLANs/SSIDs** (`unifi_wlan`).
- **Per-device radio/physical settings** (`unifi_device`) on
  already-adopted devices — channel, TX power, channel width,
  minimum-RSSI/roaming thresholds, LED behavior. Directly relevant to
  the sticky-AP roaming problem (devices in the study staying connected
  to the bar AP instead of the nearer one) — minimum-RSSI kick and
  per-radio tuning live here.
- **Firewall** — whichever model the inventory pass finds actually live
  on the controller (zone-based or legacy), not guessed up front.
- **Port forwards** (`unifi_port_forward`) and **static routes**
  (`unifi_static_route`).
- **Static client/DHCP reservations** (`unifi_user`) and **user
  groups** (`unifi_user_group`).
- Anything else inventory turns up as actually configured (DNS records,
  RADIUS profile).

**Not managed**, deliberately:

- True first-time physical device **adoption** — bringing a brand-new
  AP/switch onto the controller for the first time. Distinct from
  managing settings on an already-adopted device (which *is* in scope
  above); adoption stays a manual UI step.
- Any `setting_*` singleton still sitting at UniFi's default — importing
  a default just because the resource exists adds risk (one bad edit is
  a whole-site setting) with no benefit. Add individually later only if
  one is actually hand-tuned.

**On device icons:** checked — there's no icon/display-type attribute
anywhere in the `filipowm/unifi` provider's `unifi_device` resource. The
per-device-type pictograms in the UniFi UI are derived automatically
from the hardware model/shortname the device reports on adoption, not a
stored setting, so there's nothing to manage there.

## Layout

- `unifi-tf-app.yml` — Argo CD `Application`. Not yet in
  `apps/kustomization.yml` (see Status above).
- `unifi-tf-job.yml` — Sync-hook `Job`, same `medium: Memory` `emptyDir`
  workaround as `cloudflare-tf` (this node's default `emptyDir` is
  NFS-backed and fails Terraform's state-lock `flock()`).
- `unifi-tf-sealedsecret.yml` — not created yet, see "What's blocking a
  real apply."
- `kustomization.yml` — `configMapGenerator` with the hash suffix left
  enabled, same reasoning as `cloudflare-tf` (this ConfigMap feeds a
  Sync-hook Job, not a Deployment — the hash is what makes a
  content-only `.tf` edit visible to Argo CD's diff).
- `terraform/versions.tf`, `variables.tf` — exist now. Resource files
  (`network.tf`, `wlan.tf`, `device.tf`, `firewall.tf`,
  `port-forward.tf`, `clients.tf`) are added one at a time, per the
  rollout order above.

See `HISTORY.md` for the build log as each stage lands.
