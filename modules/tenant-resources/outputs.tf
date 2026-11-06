output "service_account_email" {
  description = "GSA for the idp-system/idp-broker KSA annotation (iam.gke.io/gcp-service-account)."
  value       = google_service_account.broker.email
}

output "service_account_member" {
  description = "IAM member string of the broker GSA (serviceAccount:...)."
  value       = google_service_account.broker.member
}

output "role_id" {
  description = "Custom role bound to the broker."
  value       = local.role_id
}

output "condition_expression" {
  description = "The IAM condition on the broker's project-level binding."
  value       = local.condition_expression
}
