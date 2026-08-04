# Written to match live state exactly, pulled from the legacy REST API's
# wlanconf endpoint during this stage's inventory (HISTORY.md #9) - not
# guessed. DRAFT: not yet wired into kustomization.yml, not imported for
# real yet - dry-run verified clean (3 to import, 0 to change), same
# discipline as network.tf (HISTORY.md #8/#9).
#
# Passphrase is a real secret (pulled live as plaintext during
# inventory) - never written here. TF_VAR_wlan_arda_home_passphrase,
# same sealed-secret treatment as the UniFi API key itself.
#
# network_id references unifi_network.default (network.tf) instead of
# hardcoding its ID - both resources import in the same plan/apply, so
# this is a real dependency, not a magic string that could drift.
#
# user_group_id is hardcoded to the built-in "Default" user group's
# legacy ID (5dcadb092d387c04fa8ff617, confirmed via legacy rest/usergroup
# - unmodified, no rate limits) - there's no unifi_user_group resource
# yet to reference (that's task 11). Revisit once user groups are
# managed for real.

resource "unifi_wlan" "arda_home" {
  name          = "ARDA_HOME"
  security      = "wpapsk"
  passphrase    = var.wlan_arda_home_passphrase
  user_group_id = "5dcadb092d387c04fa8ff617" # built-in "Default" user group
  network_id    = unifi_network.default.id

  ap_group_ids = ["607fc0bdafaf570510a1e61a"] # live: the single "All APs" group

  wlan_bands = ["2g", "5g"] # live: wlan_band "both" / wlan_bands ["2g","5g"]

  # No documented default for any of these - explicit to avoid an
  # unstated assumption, matching live exactly.
  hide_ssid          = false
  is_guest           = false
  mac_filter_enabled = false
  wpa3_support       = false
  wpa3_transition    = false
  multicast_enhance  = true # live: mcastenhance_enabled

  # Live values differ from the provider's documented defaults - must be
  # explicit (same lesson as network.tf's ipv6_ra_valid_lifetime).
  fast_roaming_enabled = true # live true, documented default false - already on,
                               # relevant to the sticky-AP roaming problem (task 8)

  # mac_filter_policy: raw legacy JSON shows "allow", but mac_filter is
  # disabled (mac_filter_enabled false, both sides) and the provider's
  # own imported-state read reports "deny" regardless - caught via
  # dry-run, not by reading the JSON myself. Trusting the provider's
  # actual read over my own raw-field interpretation, per the
  # methodology note above; functionally inert either way while
  # filtering stays off.
  mac_filter_policy = "deny"

  # Minimum data rates: raw legacy JSON's minrate_ng_enabled/
  # minrate_ng_data_rate_kbps (true/1000) looked like 2.4GHz had a real
  # minimum rate set, but the top-level minrate_setting_preference is
  # "auto", which overrides those per-band fields - confirmed via
  # dry-run, the provider's own refreshed value is 0 (disabled) for
  # both bands, not 1000. Same "don't trust your own raw-JSON reading,
  # trust the dry-run" lesson, one level more subtle than network.tf's.
  minimum_data_rate_2g_kbps = 0
  minimum_data_rate_5g_kbps = 0
}

import {
  to = unifi_wlan.arda_home
  # unifi_wlan's docs show no `name=` import format (unlike
  # unifi_network) - raw legacy _id only.
  id = "607fbf602d387c04fa8ff624"
}
