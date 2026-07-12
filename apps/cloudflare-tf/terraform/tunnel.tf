locals {
  # Ordered list matters: the catch-all (no hostname, service = http_status:404)
  # must be last, or it would swallow every request before the real rules run.
  tunnel_ingress_rules = concat(
    [for hostname, cfg in var.tunneled_hostnames : {
      hostname = hostname
      service  = cfg.origin
      origin_request = cfg.no_tls_verify ? {
        no_tls_verify = true
      } : null
    }],
    [{ service = "http_status:404" }]
  )
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "public_hostnames" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = local.tunnel_ingress_rules
  }
}
