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

## 5. Stage 2 verification hit a real snag - Argo CD parent/child sync (2026-08-04)

Merged both PRs (`unifi-tf-scaffold` and the Postgres `unifi_tf`
onboarding). First `unifi-tf-apply` run failed:
`pq: password authentication failed for user "unifi_tf"`. Root cause
wasn't the app - it was assuming a `kubectl patch ... refresh:hard` on
the **parent** Argo CD Application (`day2-services`) would cascade to
its **child** app (`postgres`). It doesn't: each child app is its own
independent `Application` object with its own `selfHeal`-driven poll
cycle against its own git path, entirely decoupled from the parent
except for the parent creating/updating the child's `Application`
resource itself. Since `postgres-app.yml` hadn't changed, refreshing
the parent had nothing to do, and `postgres` just hadn't hit its next
normal ~3-minute poll yet - so the `unifi_tf` role/database didn't
exist when Terraform tried to connect. Fixed by refreshing `postgres`
directly, then re-triggering `unifi-tf`'s own sync explicitly (Sync
hooks don't self-retry - `kubectl patch application ... operation.sync`
with the target revision). Second run succeeded cleanly: `No changes.
... Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`
**Lesson for next time**: refresh the specific child app that actually
changed, not its umbrella parent.

## 6. Inventory pass - GET-only, confirmed live (2026-08-04)

Ran the actual inventory pass (README.md's "Inventory" section has the
full findings). Worth recording the process, not just the results:
every single call was explicitly `-X GET` against either the official
Integration API (`X-API-KEY` header) or the legacy REST API - confirmed
in advance that REST semantics make `GET` inherently non-mutating, and
verified after the fact that no `POST`/`PUT`/`DELETE` was ever issued.
One assumption from secondary docs turned out wrong in a helpful way:
the legacy REST API was expected to need cookie/session auth, not the
API key - it accepted the same `X-API-KEY` header fine, so tasks
9-11 won't need a separate username/password session after all.

## 7. Client icons: a real, different answer from device icons (2026-08-04)

Same question as #4, but for end-user clients (phones, laptops, IoT)
instead of infrastructure devices (APs/switches) - and a different
answer this time. Checked `unifi_user`'s full attribute list:
`dev_id_override` ("Override the device fingerprint") is real and
Terraform-manageable. Confirmed live via the legacy REST API's
`rest/user` endpoint, which returns `dev_id`/`dev_cat`/`dev_family`/
`fingerprint_engine_version`/`confidence` per client - UniFi
auto-classifies every client via fingerprinting (MAC OUI, DHCP
fingerprint, mDNS), and that classification is what picks the icon.
There's still no literal "icon" field to set directly, but overriding
the fingerprint via `dev_id_override` changes the icon as a side
effect. Added to task 11's in-scope list for any client that's
actually been hand-overridden this way - same "only manage what's
actually customized" principle applied to the `setting_*` singletons.

## 8. network.tf: a real dry-run-only workflow, and a wrong methodology corrected (2026-08-04)

Before letting the real Sync-hook Job anywhere near `terraform import`
against the live gateway, ran a throwaway, plan-only Job (own ConfigMap
+ Job, created directly with `kubectl`, never touching git/Argo CD,
deleted after) using the same `pg` backend and sealed secrets as the
real app - `terraform init` + `terraform plan`, no `apply` step at all,
so nothing could be written even if something went wrong. It caught two
real problems before they became live changes:

**Wrong import ID format.** First attempt used the IDs from the
Integration API's `networks` list (`id`/`external_id`, UUID-shaped) -
failed with `Cannot import non-existent remote object`. This provider
is built on the legacy REST API underneath, whose network ID is a
different, 24-char ObjectId (`_id` in that API) - completely different
namespace from the Integration API's ID, despite both nominally
identifying "the same" object. Switched to the provider's `name=`
import format instead (`id = "name=Default"`) - documented as a
supported alternative, sidesteps needing either ID, self-documenting.

**Wrong methodology for "safe to omit."** The working assumption going
in was: if a field has no documented default, or matches a documented
default, it's safe to leave undeclared - Terraform will treat it as
computed and adopt whatever's live, zero drift. The dry-run plan proved
this wrong on two counts:
- `ipv6_ra_enable` (live: `true`) - leaving it undeclared didn't adopt
  the live value, it planned to null it out.
- `ipv6_ra_valid_lifetime` - the docs state a default of `86400`, but
  this console's actual live value is `0`. Leaving it undeclared meant
  Terraform planned to push the *documented* default onto live state,
  overwriting the real value - the exact opposite of "safe."
- `dhcp_start`/`dhcp_stop` on `Cluster-Backend` (DHCP disabled there) -
  assumed these didn't matter since DHCP is off, but live still has
  them stored, just inactive. Omitting them planned to null them out.
  "Disabled" is not "unset" in UniFi's data model.

**Corrected approach for every remaining stage (WLANs, devices,
firewall, etc.)**: the dry-run plan output is the only real ground
truth for "does this field need to be declared" - not the provider
docs' stated defaults, not assumptions about `Computed` behavior. Every
field in `network.tf` was verified against an actual zero-diff plan
before being considered settled - final result: `Plan: 2 to import, 0
to add, 0 to change, 0 to destroy.` This same
create-a-throwaway-plan-only-Job-first workflow should be the default
for every future resource type in this app, not just networks.

## 4. Device icons: confirmed not manageable (2026-08-04)

Asked whether the UniFi UI's per-device-type icons (AP, switch, gateway
pictograms) could be set via Terraform. Checked the `unifi_device`
resource's full attribute list in the provider docs — no icon or
display-type field anywhere. These are derived client-side from the
hardware model/shortname the device reports on adoption, not a stored
API setting. Nothing to do here, just worth recording so the question
doesn't get re-asked and re-researched later.
