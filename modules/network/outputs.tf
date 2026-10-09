output "network_id" {
  description = "VPC network ID."
  value       = google_compute_network.this.id
}

output "subnetwork_id" {
  description = "Node subnetwork ID."
  value       = google_compute_subnetwork.nodes.id
}

output "pods_range_name" {
  description = "Secondary range name for pods."
  value       = local.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for services."
  value       = local.services_range_name
}
