output "service_account_email" {
  description = "Google service account for the cert-manager Kubernetes service account annotation (iam.gke.io/gcp-service-account)."
  value       = google_service_account.dns01.email
}
