output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "endpoint" {
  description = "Public API endpoint."
  value       = google_container_cluster.this.endpoint
}

output "dns_endpoint" {
  description = "IAM-gated DNS endpoint of the control plane (no https:// prefix)."
  value       = google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "node_service_account" {
  description = "Node service account email."
  value       = google_service_account.nodes.email
}
