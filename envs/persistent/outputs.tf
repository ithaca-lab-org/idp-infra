output "registry_url" {
  description = "Docker registry URL prefix."
  value       = module.registry.url
}

output "name_servers" {
  description = "Set these as custom nameservers at Squarespace."
  value       = module.dns.name_servers
}

output "ds_record" {
  description = "DNSSEC DS record for the registrar."
  value       = module.dns.ds_record
}
