variable "project_id" {
  description = "GCP project ID that hosts the IDP."
  type        = string
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the zonal GKE cluster."
  type        = string
  default     = "us-central1-a"
}

variable "authorized_networks" {
  description = "Name to CIDR map allowed to reach the GKE API endpoint (your laptop's /32)."
  type        = map(string)
  default     = {}
}
