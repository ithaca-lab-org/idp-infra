# Vault auto-unseal with Cloud KMS (seal "gcpckms"). Persistent on purpose: the key must outlive
# the cluster (a key that is destroyed makes every Vault sealed with it unrecoverable), and the
# Workload Identity binding only names the project's identity pool and the vault/vault KSA, so it
# survives `make down` (like order-events and cert-manager-dns).
# No project-level or key-ring-level roles: both grants are on the one key. See docs/vault.md.

locals {
  wi_pool = "${var.project_id}.svc.id.goog"
}

resource "google_kms_crypto_key" "unseal" {
  name            = var.key_name
  key_ring        = var.key_ring_id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days; Vault keeps decrypting with older versions

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  labels = var.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "vault" {
  account_id   = var.account_id
  display_name = "Vault server (KMS auto-unseal)"
  description  = "Workload Identity for ${var.ksa.namespace}/${var.ksa.name}. Encrypt/decrypt with KMS key ${var.key_name} only; no project roles."
}

# Wrap and unwrap the Vault root key (cloudkms.cryptoKeyVersions.useToEncrypt / useToDecrypt).
resource "google_kms_crypto_key_iam_member" "vault_encrypter_decrypter" {
  crypto_key_id = google_kms_crypto_key.unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = google_service_account.vault.member
}

# The gcpckms seal reads the key's metadata (cloudkms.cryptoKeys.get) at startup. Granted on this
# key only: project or key-ring permissions in the role do not apply at key level.
resource "google_kms_crypto_key_iam_member" "vault_viewer" {
  crypto_key_id = google_kms_crypto_key.unseal.id
  role          = "roles/cloudkms.viewer"
  member        = google_service_account.vault.member
}

resource "google_service_account_iam_member" "vault_wi" {
  service_account_id = google_service_account.vault.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.ksa.namespace}/${var.ksa.name}]"
}
