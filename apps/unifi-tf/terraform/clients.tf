# Scope note (2026-08-04, HISTORY.md #11, corrected 2026-08-05 - see
# #14): user's stated intent is cleaned-up friendly names and a
# dev_id_override icon for every real, currently-relevant client. The
# original "76 known clients" figure was wrong scope, not wrong data -
# it's every client the controller has EVER recorded (some from 2021),
# not what the UniFi UI actually shows. Corrected scope is clients seen
# in the last 30 days (39 total, matches the UI's own count) - "if it
# hasn't connected in 30 days it's dead dead dead," user's words. This
# file does NOT attempt full name/icon cleanup yet either way. It only
# covers what's unambiguous from live data alone, without inventing
# content on the user's behalf:
#
# - Only clients where fixed_ip is ACTUALLY ACTIVE live (use_fixedip:
#   true in the legacy API - not just present-but-inactive) are
#   declared here. 13 of the original 21 fixed_ip entries have
#   use_fixedip: false - the IP is stored but not an active DHCP
#   reservation. That group includes k8smaster-m/pinode-m/valinor-m,
#   which makes sense once you think about it: those nodes get their
#   192.168.1.x addresses from their own static NetworkManager config
#   (day0-infra-build's backend_vlan_ip, see the wired-route work
#   earlier tonight), not a UniFi reservation. Declaring fixed_ip for
#   them here would CREATE a reservation that doesn't currently exist -
#   a real behavior change, not bookkeeping. Left undeclared.
# - 2 of the 8 genuinely-active fixed_ip clients (192.168.2.30 and
#   192.168.2.29) have no name set live at all - name is a REQUIRED
#   attribute on unifi_user, and inventing one would be exactly the
#   kind of content decision explicitly left to the user. Not drafted;
#   noted below with their MAC/IP so they're easy to find and add once
#   named.
# - The 51 clients with just a name and no other real customization,
#   and the other ~25 with nothing set at all, are not drafted here
#   either - the user's actual ask (clean up all 76 names, assign
#   icons) needs their direct input, not something to guess overnight.
#
# Import ID: no "Import" section documented for unifi_user. Trying the
# raw legacy _id first (same pattern as wlan/device), not yet confirmed
# via dry-run the way the resources above were.
#
# user_group_id omitted for all - live usergroup_id is empty string
# (no override) for every one of these.
#
# dev_id_override / local_dns_record: FIRST DRAFT of this file omitted
# both entirely, and the dry-run caught that as a real destructive
# mistake, not a cosmetic one - 5 of these 6 clients already have a
# real dev_id_override (icon) set, and 5 already have a real, working
# local_dns_record (e.g. googlehome-bar.i3sec.com.au). Leaving them
# undeclared would have WIPED both on apply. Pulled the complete raw
# record for each (not just the field subset used earlier) before
# writing this version - same "verify the whole object, not just the
# fields you expect to need" lesson as network.tf/wlan.tf, just a more
# expensive way to learn it. These are EXISTING live values, not
# choices made here - the deferred "pick icons for all 76 clients"
# question is unrelated and still unresolved.
#
# Also found, not carried forward here: k8smaster has a "fixed AP" pin
# defined but disabled (fixed_ap_mac -> In-Wall-Office,
# fixed_ap_enabled: false) - not in the unifi_user schema fetched for
# this file, worth checking again if a "pin a client to its nearest AP"
# approach to the roaming problem is ever revisited.

resource "unifi_user" "googlehome_lounge" {
  mac               = "48:d6:d5:db:89:2e"
  name              = "googlehome lounge"
  fixed_ip          = "192.168.2.69"
  network_id        = unifi_network.default.id
  dev_id_override   = 2028
  local_dns_record  = "googlehome-lounge.i3sec.com.au"
}

resource "unifi_user" "googlehome_shed" {
  mac               = "e4:f0:42:4e:f3:00"
  name              = "googlehome shed"
  fixed_ip          = "192.168.2.40"
  network_id        = unifi_network.default.id
  dev_id_override   = 2028
  local_dns_record  = "googlehome-shed.i3sec.com.au"
}

resource "unifi_user" "googlehome_clock" {
  mac               = "08:38:e6:35:8e:aa"
  name              = "googlehome clock"
  fixed_ip          = "192.168.2.188"
  network_id        = unifi_network.default.id
  local_dns_record  = "googlehome-clock.i3sec.com.au"
  # no dev_id_override live for this one specifically - not every
  # googlehome entry has one set, confirmed via the raw record.
}

resource "unifi_user" "googlehome_bar" {
  mac               = "00:f6:20:b3:7b:8a"
  name              = "googlehome bar"
  fixed_ip          = "192.168.2.197"
  network_id        = unifi_network.default.id
  dev_id_override   = 2028
  local_dns_record  = "googlehome-bar.i3sec.com.au"
}

resource "unifi_user" "pinode_01" {
  mac               = "2c:cf:67:27:93:f2"
  name              = "pinode-01"
  fixed_ip          = "192.168.2.11"
  network_id        = unifi_network.default.id
  dev_id_override   = 4133
  local_dns_record  = "pinode-01.i3sec.com.au"
}

resource "unifi_user" "k8smaster" {
  mac               = "88:a2:9e:2e:af:a1"
  name              = "k8smaster"
  fixed_ip          = "192.168.2.10"
  network_id        = unifi_network.default.id
  dev_id_override   = 4133
  # local_dns_record live is "" (empty) with local_dns_record_enabled
  # false - genuinely not set, unlike the others. Omitted to match.
}

# NOT drafted - no live name set, needs one from you first:
#   mac 00:08:9b:bb:ee:d9, fixed_ip 192.168.2.30
#   mac 38:a5:c9:e9:91:58, fixed_ip 192.168.2.29

import {
  to = unifi_user.googlehome_lounge
  id = "6093b3ac954f510349ac2fe0"
}
import {
  to = unifi_user.googlehome_shed
  id = "641e298a32c35b0378eb6c71"
}
import {
  to = unifi_user.googlehome_clock
  id = "641e2ab032c35b0378eb6cbf"
}
import {
  to = unifi_user.googlehome_bar
  id = "641e483677ae6e03709d987a"
}
import {
  to = unifi_user.pinode_01
  id = "665b108008b72b5443c99d09"
}
import {
  to = unifi_user.k8smaster
  id = "68c26d0a1da50b72d5255550"
}
