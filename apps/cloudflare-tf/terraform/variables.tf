variable "cloudflare_api_token" {
  description = "Cloudflare API token, injected as TF_VAR_cloudflare_api_token from the cloudflare-tf-secrets SealedSecret."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID for Brett@i3sec.com.au's Account."
  type        = string
  default     = "c0ef76e1433049d74bcc9f96229eb866"
}

variable "zone_id" {
  description = "Zone ID for i3sec.com.au, injected as TF_VAR_zone_id from the cloudflare-tf-secrets SealedSecret."
  type        = string
}

variable "cloudflare_tunnel_id" {
  description = "UUID of the existing cloudflared Tunnel (token-based, created via the Zero Trust dashboard). Not a secret - an identifier, not a credential - visible in Zero Trust > Networks > Tunnels."
  type        = string
  default     = "e5de1f51-45bd-4357-83e8-9fb6574b8339"
}

variable "tunneled_hostnames" {
  description = <<-EOT
    Single source of truth for every hostname exposed via the Cloudflare
    Tunnel. Drives the tunnel's ingress config
    (cloudflare_zero_trust_tunnel_cloudflared_config, tunnel.tf), the
    public DNS record for each hostname (cloudflare_dns_record, tunnel.tf),
    the mTLS WAF rule's protected-hostname list (waf.tf, derived via
    keys()), and the mTLS Client Certificate hostname list
    (cloudflare_certificate_authorities_hostname_associations, waf.tf) -
    add a hostname here once and all four update. See README.md/HISTORY.md
    for why it took four separate resources to get here.

    `origin` defaults to the shared ingress-nginx-controller Service every
    k8s-hosted app in this cluster is fronted by (Cloudflare forwards by
    Host header; ingress-nginx does the final per-app routing via each
    app's own Ingress). Only override `origin` for things that aren't a
    k8s Service behind that controller - e.g. qnap, a physical NAS.
  EOT
  type = map(object({
    origin        = optional(string, "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80")
    no_tls_verify = optional(bool, false)
  }))
  default = {
    "argocd.i3sec.com.au"        = {}
    "books.i3sec.com.au"         = {}
    "vscode.i3sec.com.au"        = {}
    "homeassistant.i3sec.com.au" = {}
    # obsidian.i3sec.com.au itself is a redirect-only host (see
    # day2-services apps/obsidian/obsidian-public-ingress.yml) - the
    # actual noVNC/websockify traffic lands on novnc.i3sec.com.au, which
    # must be tunneled too or the redirect target is unreachable from
    # outside the LAN. Both added together 2026-07-18, not independently.
    "obsidian.i3sec.com.au"      = {}
    "novnc.i3sec.com.au"         = {}
    "qnap.i3sec.com.au" = {
      origin        = "https://192.168.2.30:443"
      no_tls_verify = true # confirmed 2026-07-15: QNAP (QTS) serves a self-signed cert even after regenerating it with a correct CN/SAN for qnap.i3sec.com.au - cloudflared has no way to verify it against a public CA, so this stays true. Unrelated to the iPad LAN-side cert trust fix from the same date (see dns-conf/pihole/README.md) - that only covers direct browser access, not cloudflared's origin connection.
    }
  }
}

variable "allowed_client_cert_fingerprints" {
  description = "SHA-256 fingerprints of specific client certs permitted to pass the mTLS WAF rule. Empty = accept any cert issued under this account's CA (current behavior). Populate to pin to exact devices."
  type    = list(string)
  default = []
}

variable "k8smaster_lan_ip" {
  description = "LAN IP of the k3s control-plane node, reachable over the tunnel's private network route once WARP is enrolled."
  type        = string
  default     = "192.168.2.10"
}

variable "warp_authorized_emails" {
  description = "Only these emails may enroll a device in Cloudflare WARP for this account. Auth still goes through the onetimepin IdP - this just gates who's allowed to complete enrollment."
  type        = list(string)
  default     = ["gorttman@i3sec.com.au", "brett@i3sec.com.au"]
}
