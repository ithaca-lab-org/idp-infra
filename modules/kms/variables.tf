variable "project_number" {
  description = "GCP project number (builds the GKE service agent address)."
  type        = string
}

variable "location" {
  description = "KMS location. Must match the cluster's region."
  type        = string
}

variable "key_ring_name" {
  description = "Name of the key ring."
  type        = string
  default     = "idp"
}
