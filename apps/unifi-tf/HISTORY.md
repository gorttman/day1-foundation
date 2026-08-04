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
