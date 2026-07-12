output "mtls_rule_expression" {
  description = "The actual WAF rule expression applied — check this in plan output before it's ever allowed to run against a real token."
  value       = local.mtls_block_expression
}

output "mtls_ruleset_id" {
  value = cloudflare_ruleset.zone_mtls_enforcement.id
}
