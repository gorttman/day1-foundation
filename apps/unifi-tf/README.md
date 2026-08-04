# unifi-tf

Manages the UniFi Dream Machine's config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job — the same pattern
`apps/cloudflare-tf` uses, applied to the household network instead of
the Cloudflare edge. Scope is "everything that can be" managed as code:
networks/VLANs, WLANs, per-device radio/physical settings, firewall,
port forwards, static routes, static DHCP reservations, user groups.

**Status:** scaffolding only. `unifi-tf-app.yml` is deliberately **not**
yet registered in `apps/kustomization.yml`, and `unifi-tf-sealedsecret.yml`
doesn't exist yet — see "What's blocking a real apply" below.

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

## What's blocking a real apply

A UniFi API credential, created by hand (can't be scripted without one
already existing — same one-time manual step `cloudflare-tf` needed for
its Cloudflare API token):

1. Check the Dream Machine's firmware version (Settings → System). API-key
   auth (preferred — see below) needs **≥ 9.0.108**.
2. If firmware qualifies: Control Plane → Admins & Users → your admin →
   **Create API Key**. Copy it immediately, it's only shown once.
3. If firmware is older: create a dedicated local admin account instead
   (not the console SSO login) — username/password is the fallback auth
   method, already wired as `var.unifi_username`/`var.unifi_password` in
   `terraform/variables.tf`, just not yet the active method in
   `terraform/versions.tf`'s `provider "unifi"` block.
4. Once you have either, the credential + firmware version gets sealed
   into `unifi-tf-secrets` (same `kubeseal --raw` pattern as
   `cloudflare-tf-secrets` — see that app's README for the exact
   command shape) and this README gets updated with the real runbook.

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
