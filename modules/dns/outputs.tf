output "zone_name" {
  description = "Managed zone name."
  value       = google_dns_managed_zone.this.name
}

output "name_servers" {
  description = "Set these as the custom nameservers at the registrar."
  value       = google_dns_managed_zone.this.name_servers
}

output "ds_record" {
  description = "DNSSEC DS record to add at the registrar (key tag, algorithm, digest)."
  value       = data.google_dns_keys.this.key_signing_keys[0].ds_record
}

data "google_dns_keys" "this" {
  managed_zone = google_dns_managed_zone.this.id
}
