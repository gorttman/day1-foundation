# unifi-tf

Manages the UniFi Dream Machine's config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job — the same pattern
`apps/cloudflare-tf` uses, applied to the household network instead of
the Cloudflare edge. Scope is "everything that can be" managed as code:
networks/VLANs, WLANs, per-device radio/physical settings, firewall,
port forwards, static routes, static DHCP reservations, user groups.

**Status (2026-08-04, end of session):** real resources exist on the
live gateway now, not just drafts — but only a deliberately-chosen
subset, applied one at a time with a canary-first approach, all through
throwaway `kubectl`-created Jobs against the real backend, **not**
through the GitOps path (`unifi-tf-app.yml` is still not registered in
`apps/kustomization.yml`, nothing here is Argo CD-managed yet):

- **Applied for real**: `unifi_device.uap_shed` (canary — 3 low-stakes
  IoT clients, zero detectable disruption), then
  `in_wall_bedroom`/`in_wall_office`/`in_wall_bar`/`in_wall_lounge`
  together. That second batch caused real, visible client roaming
  (`Gateway`'s own radio picked up 17 clients displaced from the 4 APs)
  — network stayed up, nothing lost, but it was a genuine blip, not a
  non-event. See HISTORY.md #11 for the full canary methodology and
  the roaming finding.
- **Still draft-only, dry-run verified clean, NOT applied**:
  `network.tf` (2 networks), `wlan.tf` (`ARDA_HOME`), the 3 remaining
  devices (`switch_mainnet`, `switch_picluster`, `gateway` —
  deliberately held back, different risk class, see HISTORY.md #10/#11),
  `security-settings.tf` (IPS/threat prevention — genuinely
  non-default, see below and HISTORY.md #12), and `clients.tf` (6 of 39
  recently-active known clients, the only ones with unambiguous live
  data to capture — client scope corrected 2026-08-05, see HISTORY.md
  #13/#14). `firewall.tf`/`port-forward.tf` are intentionally empty,
  confirmed live twice.
- Every file above passes a combined dry-run together (`terraform
  plan` against the real backend, real state, zero `apply`) with only
  the two expected/benign diff patterns: synthetic create-time flags
  (`allow_existing`, `forget_on_destroy`, etc.) and same-plan resource
  references not yet resolved (`network_id`/`tx_power`-style "known
  after apply", which self-resolves once the referenced resource is
  actually applied for real).

Next real step: your call on when (and whether) to wire the rest in
for real, given the roaming blip from the last batch.

## Prerequisite: the control path must be wired, not WLAN

Both cluster nodes (`k8smaster`, `pinode-01` — the only two places the
Sync-hook Job can land) used to reach the UDM's own API over `wlan0`,
not their wired NICs, purely because `wlan0` happens to sit directly on
the same subnet as the gateway's management address. That's a real
risk specific to this app: a WLAN-disrupting apply (a radio change, the
WLAN resource itself) could cut the very control path being used to
manage it, mid-apply, with no visibility to recover. Fixed
(2026-08-04) with a `/32` host route on both nodes — see HISTORY.md
#10 for the full story, and `day0-infra-build`'s
`unifi-tf-backend-route` branch for the codified version. Verify this
is still in place (`ip route get 192.168.2.1` should show a wired
device, not `wlan0`) before trusting any future apply here.

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

## Inventory (2026-08-04)

Read-only pass against the live console — every call was HTTP `GET`
against either the official Integration API
(`/proxy/network/integration/v1/sites/{siteId}/...`, `X-API-KEY` auth)
or the legacy REST API (`/proxy/network/api/s/default/rest/...`, which
turned out to accept the same API key — no separate username/password
session needed after all). Nothing was created, modified, or deleted;
`GET` is inherently non-mutating for both APIs. Findings:

- **Firewall model**: `firewall/zones` → `"Zone Based Firewall is not
  configured"` — this console runs the **legacy** model. Both
  `firewallgroup` and `firewallrule`/`portforward` are currently
  **empty** — a clean slate for tasks 9/10, nothing existing to
  reverse-engineer.
- **Networks (2 user-facing, plus system WAN)**: `Default` (VLAN 1,
  system default) and `Cluster-Backend` (VLAN 10 — the k3s cluster's
  network). Legacy `networkconf` also lists `Internet 1`
  (`purpose: wan`) — system-managed, not a `unifi_network` candidate.
- **WLANs (1)**: `ARDA_HOME`, WPA2-Personal, dual-band (2.4 + 5 GHz).
- **Devices (8)**: 2 switches (`Switch-MainNet`, `Switch-PiCluster`,
  both US 8 PoE 150W) and 6 APs (`UAP - Shed` / AC Pro,
  `In-Wall-Office` / AC IW, `In-Wall-Bedroom` / IW HD, `In-Wall Lounge`
  / U6 IW, `In-Wall-Bar` / U6 IW). No AP is literally named "study" —
  `In-Wall-Office` is the likely candidate for the roaming problem's
  "study AP," not confirmed. The Integration API's per-device `GET`
  only returns *current observed* radio state (channel/width/frequency),
  not the full configurable field set (`tx_power_mode`, `min_rssi`,
  etc.) — task 8's actual read/import will need the legacy REST API for
  those, same as it turned out firewall/port-forward did.
- **31 live clients** currently connected — a different, larger set
  than task 11's static/DHCP-reservation `unifi_user` entries, not yet
  pulled separately.

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
- **Firewall** — legacy model (`firewall_group`/`firewall_rule`),
  confirmed by the inventory pass (see below), not zone-based.
- **Port forwards** (`unifi_port_forward`) and **static routes**
  (`unifi_static_route`).
- **Static client/DHCP reservations** (`unifi_user`) and **user
  groups** (`unifi_user_group`) — including each client's `name`,
  `note`, `fixed_ip`, `network_id`, `user_group_id`, `blocked` state,
  and `dev_id_override` (see "On client icons" below).
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

**On infrastructure device icons** (APs/switches/gateway): checked —
there's no icon/display-type attribute anywhere in the `filipowm/unifi`
provider's `unifi_device` resource. Those pictograms are derived
automatically from the hardware model/shortname the device reports on
adoption, not a stored setting, so there's nothing to manage there.

**On client icons** (end-user devices — phones, laptops, IoT): different
answer. UniFi classifies every client via automatic fingerprinting (MAC
OUI, DHCP fingerprint, mDNS, etc.) into a `dev_id`/`dev_cat`/`dev_family`
combination that decides which icon renders — confirmed live via the
legacy REST API's `rest/user` endpoint, which returns those fields per
client alongside a `fingerprint_engine_version`/`confidence` score. The
icon itself still isn't a stored, freestanding setting — but the
classification *can* be overridden: `unifi_user`'s `dev_id_override`
attribute ("Override the device fingerprint") is real and Terraform-
manageable, which changes the icon as a side effect of overriding the
fingerprint match. Confirmed with real live examples now, not just
theory: the 5 Google Home/Linux-host clients in `clients.tf` already
have real `dev_id_override` values set (`2028`, `4133`) — captured as
existing state, not invented. What's still unresolved: what numeric
`dev_id` values actually *mean* (no public Ubiquiti lookup table found,
see HISTORY.md #7) — fine for preserving existing overrides, blocking
for choosing new ones on the remaining clients. User's explicit call
(2026-08-04): "not sure, let's cover it when we get there." Scope for
"the remaining clients" corrected 2026-08-05 (HISTORY.md #14): clients
seen in the last 30 days only (39 total, 33 beyond the 6 already
drafted), not the full 76-deep all-time history — "if it hasn't
connected in 30 days it's dead dead dead."

## Security settings — a real exception to "don't manage defaults"

`security-settings.tf` (`unifi_setting_ips`) is genuinely NOT at
UniFi's default — IPS/threat prevention is actively enabled in
blocking mode (`ips_mode: "ips"`) with a real, curated 11-category
threat list, confirmed live via `get/setting` (`key=ips`). Exactly the
kind of hand-tuned setting the "don't manage default singletons" rule
in Scope above was always meant to include, not exclude. `utm_token` (a
real secret-looking value in the live data) has no attribute anywhere
in this provider's schema — almost certainly Ubiquiti-cloud-issued and
system-managed, so nothing sensitive ends up in this file.

## Layout

- `unifi-tf-app.yml` — Argo CD `Application`. Not yet in
  `apps/kustomization.yml` (see Status above).
- `unifi-tf-job.yml` — Sync-hook `Job`, same `medium: Memory` `emptyDir`
  workaround as `cloudflare-tf` (this node's default `emptyDir` is
  NFS-backed and fails Terraform's state-lock `flock()`).
- `unifi-tf-sealedsecret.yml` — exists, sealed for real (API key +
  Postgres conn string). `wlan_arda_home_passphrase` is drafted as a
  variable but NOT yet resealed into this file — `wlan.tf` isn't
  applied for real yet, so there's nothing live depending on it.
- `kustomization.yml` — `configMapGenerator` with the hash suffix left
  enabled, same reasoning as `cloudflare-tf` (this ConfigMap feeds a
  Sync-hook Job, not a Deployment — the hash is what makes a
  content-only `.tf` edit visible to Argo CD's diff). Still only lists
  `versions.tf`/`variables.tf` — the rest of the resource files aren't
  wired into the real ConfigMap yet (see Status above).
- `terraform/` — `versions.tf`, `variables.tf`, `network.tf`,
  `wlan.tf`, `device.tf`, `firewall.tf`, `port-forward.tf`,
  `security-settings.tf`, `clients.tf` all exist and are dry-run
  verified. See Status above for which are also applied for real.

See `HISTORY.md` for the build log as each stage lands.
