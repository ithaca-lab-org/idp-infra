output "gke_secrets_key_id" {
  description = "Crypto key ID for GKE application-layer secrets encryption."
  value       = google_kms_crypto_key.gke_secrets.id
}
