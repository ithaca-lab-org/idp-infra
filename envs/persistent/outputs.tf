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

output "ingress_ip" {
  description = "Reserved IP for the Istio ingress gateway (*.apps.<domain> points here)."
  value       = module.ingress.ip_address
}

output "cert_manager_dns01_sa" {
  description = "Google service account for cert-manager's DNS-01 solver."
  value       = module.cert_manager_dns.service_account_email
}
