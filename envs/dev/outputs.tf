output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.name
}

output "get_credentials" {
  description = "Command that configures kubectl."
  value       = "gcloud container clusters get-credentials ${module.gke.name} --dns-endpoint --zone ${var.zone} --project ${var.project_id}"
}
