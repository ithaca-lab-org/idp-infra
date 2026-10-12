output "ip_address" {
  description = "Reserved external IP for the ingress gateway."
  value       = google_compute_address.ingress.address
}

output "wildcard_record" {
  description = "Wildcard DNS name pointing at the ingress IP."
  value       = google_dns_record_set.apps_wildcard.name
}
