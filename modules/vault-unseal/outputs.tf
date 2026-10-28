output "key_name" {
  description = "Unseal key name (Vault seal \"gcpckms\" crypto_key)."
  value       = google_kms_crypto_key.unseal.name
}

output "key_id" {
  description = "Full resource ID of the unseal key."
  value       = google_kms_crypto_key.unseal.id
}

output "service_account_email" {
  description = "GSA for the vault/vault KSA annotation (iam.gke.io/gcp-service-account)."
  value       = google_service_account.vault.email
}
