# WARP client access to k8smaster (192.168.2.10) for off-LAN SSH, e.g. while
# travelling. Three pieces, all required together:
#
#   1. A private network route on the existing tunnel, so 192.168.2.10 is
#      reachable through it at all.
#   2. The account's default WARP device profile, switched from its stock
#      "exclude everything private" split-tunnel mode to "include only
#      k8smaster" mode. This account has no other Zero Trust use case (no
#      other Access apps, no Gateway filtering depended on today), so
#      routing *only* k8smaster through WARP - and letting all other device
#      traffic bypass WARP entirely - is simpler and lower-impact than
#      carving a single /32 hole out of the existing 192.168.0.0/16 exclude
#      (which would need ~16 explicit complement CIDRs to express and would
#      pull all other traffic through Cloudflare for every enrolled device).
#   3. A `warp`-type Access Application gating device enrollment to just the
#      two people who'll ever use this - everyone else's OTP still gets
#      accepted by the identity provider, but only these emails are allowed
#      to finish enrolling a device.
#
# Once enrolled, SSH itself is unchanged: same key, same `ssh 192.168.2.10`,
# WARP only provides the network path when off the home LAN.

resource "cloudflare_zero_trust_tunnel_cloudflared_route" "k8smaster" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "${var.k8smaster_lan_ip}/32"
  comment    = "k8smaster - private SSH access via WARP"
}

# Pre-existing singleton (one per account, created outside Terraform) -
# import required before the first apply: see README.md.
resource "cloudflare_zero_trust_device_default_profile" "this" {
  account_id = var.account_id

  include = [{
    address     = "${var.k8smaster_lan_ip}/32"
    description = "k8smaster - private SSH access"
  }]
}

resource "cloudflare_zero_trust_access_application" "warp_enrollment" {
  account_id = var.account_id
  type       = "warp"
  name       = "WARP Client Enrollment"

  policies = [{
    name       = "Authorized WARP users"
    decision   = "allow"
    precedence = 1
    include    = [for email in var.warp_authorized_emails : { email = { email = email } }]
  }]
}
