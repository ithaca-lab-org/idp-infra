output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "endpoint" {
  description = "Public API endpoint."
  value       = google_container_cluster.this.endpoint
}

output "node_service_account" {
  description = "Node service account email."
  value       = google_service_account.nodes.email
}
