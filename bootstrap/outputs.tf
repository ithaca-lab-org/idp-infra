output "state_bucket" {
  description = "GCS bucket holding Terraform state for every IDP stack."
  value       = google_storage_bucket.tfstate.name
}

output "workload_identity_provider" {
  description = "Full provider name for google-github-actions/auth `workload_identity_provider`."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "plan_service_account" {
  description = "Service account for PR plans (`service_account` input of google-github-actions/auth)."
  value       = google_service_account.terraform_plan.email
}

output "apply_service_account" {
  description = "Service account for applies from the protected branch."
  value       = google_service_account.terraform_apply.email
}
