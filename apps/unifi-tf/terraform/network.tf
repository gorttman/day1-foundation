# Written to match live state exactly, pulled from the legacy REST API's
# networkconf endpoint during the inventory pass (README.md's "Inventory"
# section, HISTORY.md #6) - not guessed. DRAFT: not yet wired into
# kustomization.yml's configMapGenerator, and neither resource has been
# terraform import'd into state yet - both still need to happen before
# this is safe to let selfHeal touch. "Internet 1" (purpose = wan) is
# intentionally NOT declared here - it's the system-managed WAN network,
# not a candidate for unifi_network (see README.md's Inventory section).

resource "unifi_network" "default" {
  name    = "Default"
  purpose = "corporate"
  subnet  = "192.168.2.1/24"
  # vlan_id intentionally omitted - live config has vlan_enabled: false,
  # this is the untagged/native network, not an explicitly tagged VLAN 1.

  domain_name = "i3sec.com.au"
  internet_access_enabled = true
  multicast_dns = true # live: mdns_enabled true

  dhcp_enabled = true
  dhcp_start = "192.168.2.6"
  dhcp_stop = "192.168.2.239"
  # live: dhcpd_dns_1/dhcpd_dns_2 - k8smaster first, then the gateway
  # itself as a fallback resolver.
  dhcp_dns = ["192.168.2.10", "192.168.2.1"]
}

resource "unifi_network" "cluster_backend" {
  name    = "Cluster-Backend"
  purpose = "corporate"
  subnet  = "192.168.1.1/27"
  vlan_id = 10

  internet_access_enabled = false # live: internet_access_enabled false
  multicast_dns = false # live: mdns_enabled false
  dhcp_enabled = false # live: dhcpd_enabled false - no DHCP range set
}
