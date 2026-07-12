locals {
  mtls_protected_hostnames = keys(var.tunneled_hostnames)

  hostname_set = join(" ", [for h in local.mtls_protected_hostnames : "\"${h}\""])

  fingerprint_clause = length(var.allowed_client_cert_fingerprints) > 0 ? (
    " or not (cf.tls_client_auth.cert_fingerprint_sha256 in {${join(" ", [for fp in var.allowed_client_cert_fingerprints : "\"${fp}\""])}})"
  ) : ""

  mtls_block_expression = "http.host in {${local.hostname_set}} and (not cf.tls_client_auth.cert_verified or cf.tls_client_auth.cert_revoked${local.fingerprint_clause})"
}

resource "cloudflare_ruleset" "zone_mtls_enforcement" {
  zone_id     = var.zone_id
  name        = "Enforce mTLS on i3sec.com.au Services"
  description = "Blocks requests to protected self-hosted apps unless a valid, non-revoked client certificate is presented."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [{
    ref         = "enforce_mtls_web_apps"
    description = "Block if client cert missing, unverified, revoked, or (if fingerprint pinning is enabled) not an allow-listed device"
    expression  = local.mtls_block_expression
    action      = "block"
    enabled     = true
  }]
}
