variable "project_id" {
  description = "GCP project ID (builds the Workload Identity pool name)."
  type        = string
}

variable "key_ring_id" {
  description = "ID of the existing key ring (modules/kms) that holds the unseal key."
  type        = string
}

variable "key_name" {
  description = "Name of the Vault unseal key."
  type        = string
  default     = "vault-unseal"
}

variable "account_id" {
  description = "Account ID of the Google service account the Vault server runs as."
  type        = string
  default     = "vault"
}

variable "ksa" {
  description = "Kubernetes service account (namespace and name) of the Vault server."
  type        = object({ namespace = string, name = string })
  default     = { namespace = "vault", name = "vault" }
}

variable "labels" {
  description = "Labels for the crypto key."
  type        = map(string)
  default     = { app = "vault", stack = "idp" }
}
