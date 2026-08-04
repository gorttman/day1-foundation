# Written to match live state exactly, pulled from the legacy REST API's
# networkconf endpoint during the inventory pass (README.md's "Inventory"
# section, HISTORY.md #6) - not guessed. DRAFT: not yet wired into
# kustomization.yml's configMapGenerator, and neither resource has been
# terraform import'd into state yet - both still need to happen before
# this is safe to let selfHeal touch. "Internet 1" (purpose = wan) is
# intentionally NOT declared here - it's the system-managed WAN network,
# not a candidate for unifi_network (see README.md's Inventory section).
#
# Fields deliberately NOT declared, in two different categories:
#
# 1. Matches a documented provider default, so omitting is zero-drift-risk
#    (enabled=true, network_group="LAN", dhcp_lease=86400,
#    ipv6_interface_type="none", network_isolation_enabled=false).
#
# 2. No Terraform equivalent exists at all in this provider version - real
#    live settings, genuinely unmanageable via unifi_network today:
#    is_nat, nat_outbound_ip_addresses, dhcpd_conflict_checking,
#    dhcpd_wins_enabled, dhcpd_time_offset_enabled, dhcpd_wpad_url,
#    dhcpd_ntp_enabled, dhcpd_tftp_server, dhcpd_unifi_controller,
#    lte_lan_enabled, auto_scale_enabled, gateway_type,
#    setting_preference. All of these stay dashboard-only.
#
# IPv6 (ipv6_ra_enable/ipv6_ra_priority/etc.) is also NOT declared, even
# though live has ipv6_ra_enabled: true / priority: high - those fields
# have no documented default in the provider, but ipv6_interface_type
# ("none") is what actually gates whether IPv6 does anything on this
# network, and that one DOES default to "none" matching live. Leaving
# the RA fields undeclared means Terraform treats them as computed
# (adopts whatever's live on import, no drift) rather than guessing at
# an unstated default.

resource "unifi_network" "default" {
  name    = "Default"
  purpose = "corporate"
  subnet  = "192.168.2.1/24"
  # vlan_id intentionally omitted - live config has vlan_enabled: false,
  # this is the untagged/native network, not an explicitly tagged VLAN 1.

  domain_name = "i3sec.com.au"
  internet_access_enabled = true
  multicast_dns = true # live: mdns_enabled - no documented default, must be explicit

  dhcp_enabled = true
  dhcp_start = "192.168.2.6"
  dhcp_stop = "192.168.2.239"
  # live: dhcpd_dns_1/dhcpd_dns_2 - k8smaster first, then the gateway
  # itself as a fallback resolver.
  dhcp_dns = ["192.168.2.10", "192.168.2.1"]

  # No documented default for any of these four - explicit to avoid
  # relying on an unstated assumption, all match live (all false).
  igmp_snooping        = false
  dhcp_guarding         = false # live: dhcpguard_enabled
  dhcpd_gateway_enabled = false # live: gateway auto-derived from subnet
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false
}

resource "unifi_network" "cluster_backend" {
  name    = "Cluster-Backend"
  purpose = "corporate"
  subnet  = "192.168.1.1/27"
  vlan_id = 10

  internet_access_enabled = false # live: internet_access_enabled false
  multicast_dns = false # live: mdns_enabled false - no documented default
  dhcp_enabled = false # live: dhcpd_enabled false - no DHCP range set

  igmp_snooping        = false
  dhcp_guarding         = false
  dhcpd_gateway_enabled = false
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false
}
