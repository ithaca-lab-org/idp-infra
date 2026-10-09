# Key rings and keys can never be deleted in GCP, so this lives in the
# persistent stack and is never part of `make down`.
resource "google_kms_key_ring" "this" {
  name     = var.key_ring_name
  location = var.location
}

resource "google_kms_crypto_key" "gke_secrets" {
  name            = "gke-secrets"
  key_ring        = google_kms_key_ring.this.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# GKE's control plane encrypts/decrypts etcd secrets with this key.
resource "google_kms_crypto_key_iam_member" "gke_agent" {
  crypto_key_id = google_kms_crypto_key.gke_secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}
