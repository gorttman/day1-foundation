# unifi-tf: build history, mistakes, and fixes

Full narrative of building this app, for institutional memory. Same
convention as `cloudflare-tf/HISTORY.md` — if something looks weird in
the code, the answer is probably in here.

## The goal

Bring the UniFi Dream Machine's config — networks/VLANs, WLANs,
per-device radio settings, firewall, port forwards, static routes,
static DHCP reservations — under Terraform, run in-cluster by an Argo CD
Sync-hook Job, same architecture as `cloudflare-tf`. Motivating problem:
a sticky-AP/roaming issue where devices in the study stay connected to
the bar AP in another room instead of the nearer study AP — likely
fixable via WLAN minimum-RSSI/band-steering settings and/or per-AP radio
tuning, both in scope for this app.

## 1. Provider choice: `filipowm/unifi` over `paultyng/unifi` (2026-08-04)

Researched both before writing anything. `paultyng/unifi` is the
better-known provider (it's what most tutorials reference), but its own
docs say it caps out at controller v6.x support with password-only auth.
`filipowm/unifi` is an actively maintained fork with explicit
UDM/UDM-Pro/UCG support, API-key auth (needs controller ≥ 9.0.108), and
much broader resource coverage. Confirmed via the provider's GitHub docs
directly (`raw.githubusercontent.com/filipowm/terraform-provider-unifi`)
since the Terraform Registry's own docs page is JS-rendered and doesn't
return real content to a headless fetch.

## 2. Scope revision: device settings went from "excluded" to "in scope" (2026-08-04)

First draft of the plan excluded `unifi_device` entirely (physical
AP/switch management) on the reasoning that hardware-state changes carry
disproportionate disruption risk for a homelab. Revised same day once
the actual motivating problem (sticky-AP roaming) came up — per-AP
radio/TX-power/minimum-RSSI tuning needs `unifi_device`, so excluding it
entirely would have excluded the actual fix. Landed on a narrower line
instead: **settings** on an already-adopted device are in scope,
first-time device **adoption** stays manual. Those are genuinely
different operations with different risk profiles — adoption is a
one-time hardware-pairing action, settings changes on an adopted device
are what this whole app is for.

## 3. Finding the API key: wrong guesses, then the real location (2026-08-04)

Two wrong menu-path guesses before landing on the right one, worth
recording so nobody re-treads this: guessed "Settings → System" for the
firmware version (wrong - firmware/UDM version and the Network
application version are two different numbers shown in different
places, and the one that actually matters for API-key auth eligibility
is the **Network application version**, not the UDM/UniFi-OS version -
confirmed 10.5.67 vs 9.0.108 minimum). Then guessed "Control Plane →
Admins & Users → Create API Key" for the key itself - also wrong, and
also based on stale/generic documentation, not this specific version.

The real location, confirmed live: **Integrations** page inside the
local UniFi Network application itself → Create New API Key. This is
deliberately the **Network Application API key**, not a **Site Manager
API key** (created separately at unifi.ui.com, routes through
Ubiquiti's cloud) - the two are different credential systems for
different connectivity models, and only the Network Application key
works for a direct local-IP integration like this one. Created with no
expiry (see README.md's Secrets section) since there's no rotation
automation in this pipeline yet - an automated rotation integration is
a real future idea, just not built as part of this initial setup.

## 4. Device icons: confirmed not manageable (2026-08-04)

Asked whether the UniFi UI's per-device-type icons (AP, switch, gateway
pictograms) could be set via Terraform. Checked the `unifi_device`
resource's full attribute list in the provider docs — no icon or
display-type field anywhere. These are derived client-side from the
hardware model/shortname the device reports on adoption, not a stored
API setting. Nothing to do here, just worth recording so the question
doesn't get re-asked and re-researched later.

## 5. INCIDENT: a stale-branch WLAN destroyed the house Wi-Fi (2026-08-05)

**Symptom:** the whole household Wi-Fi went offline. Wired stayed up.

**Root cause: config/state divergence, detonated by an unrelated sync.**
In an earlier session a `wlan.tf` (the `ARDA_HOME` WLAN) was written and
`terraform apply`ed for real — creating a `unifi_wlan.ARDA_HOME` object
in the shared Postgres state — but that work lived on a feature branch
that was **never merged to `main`**. `wlan.tf` therefore exists in no
branch, and `main`'s config (the `configMapGenerator` in
`kustomization.yml`) still lists only `versions.tf` + `variables.tf`.
Net result: the WLAN existed **in state but not in config**.

The trigger was the very next commit to land on `main` — `6f5c84d`,
which only sealed the WLAN passphrase field into the SealedSecret. That
changed the `unifi-tf-secrets` Secret, Argo CD synced the app (which has
`syncPolicy.automated.selfHeal: true`), the Sync-hook Job ran
`terraform apply`, Terraform saw a resource in state but absent from
config → **planned a destroy → deleted the live WLAN.** House offline.

The passphrase commit did not cause the bug; it tripped a landmine that
had been armed the moment `wlan.tf` was applied-but-not-merged.

**Fix (this change): a destroy-guard in `unifi-tf-job.yml`.** The Job now
parses the plan between `plan` and `apply`; if the plan would destroy any
resource it fails the sync loudly instead of applying, unless a human
sets `UNIFI_TF_ALLOW_DESTROY=true`. An automated selfHeal can now add and
change, but it can never silently delete a live network object — which is
precisely the failure mode above. This would have turned the outage into
a red sync notification and no lost Wi-Fi.

**Recovery (manual, once LAN access is regained):**
1. `argocd app set unifi-tf --sync-policy none` — freeze the app first.
2. Recreate the `ARDA_HOME` SSID in the Network UI (name + sealed
   passphrase) to bring Wi-Fi back immediately.
3. `terraform state list` to confirm the WLAN was the only casualty.
4. Leave the app disabled. `unifi-tf-app.yml` now ships with
   `syncPolicy: {}` (automated sync off) so nothing re-applies on its own
   - a live `kubectl patch` freeze alone is not durable, because an
   app-of-apps reconcile would restore whatever git says. Re-arm the
   `automated` block deliberately, only once the destroy-guard has been
   confirmed against a real plan/apply.

**Lesson:** never `terraform apply` this app from a branch whose config
isn't what lands on `main`. The shared pg backend means a branch apply
mutates the *same* state `main` reconciles against — so a real apply and
its merge to `main` must happen together, or `main` will "correct" the
difference by deleting whatever the branch added. Re-adding `wlan.tf`
later must follow the README's rollout rule: `terraform import` against
the live object, committed to `main` in the same change.
