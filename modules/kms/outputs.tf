output "gke_secrets_key_id" {
  description = "Crypto key ID for GKE application-layer secrets encryption."
  value       = google_kms_crypto_key.gke_secrets.id
}

output "key_ring_id" {
  description = "Key ring ID (other keys, such as the Vault unseal key, are added to this ring)."
  value       = google_kms_key_ring.this.id
}

output "key_ring_name" {
  description = "Key ring name."
  value       = google_kms_key_ring.this.name
}

output "location" {
  description = "Key ring location."
  value       = google_kms_key_ring.this.location
}
