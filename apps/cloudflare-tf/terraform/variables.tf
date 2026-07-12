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

variable "mtls_protected_hostnames" {
  description = "Hostnames enforced by the mTLS WAF block rule. NOT the same as the TLS-layer 'Hosts' list under SSL/TLS > Client Certificates, which has no Terraform resource and stays a manual dashboard setting."
  type    = list(string)
  default = ["argocd.i3sec.com.au", "books.i3sec.com.au", "qnap.i3sec.com.au"]
}

variable "allowed_client_cert_fingerprints" {
  description = "SHA-256 fingerprints of specific client certs permitted to pass the mTLS WAF rule. Empty = accept any cert issued under this account's CA (current behavior). Populate to pin to exact devices."
  type    = list(string)
  default = []
}
