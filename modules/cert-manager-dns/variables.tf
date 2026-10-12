variable "project_id" {
  description = "GCP project ID (builds the Workload Identity pool name)."
  type        = string
}

variable "zone_name" {
  description = "Cloud DNS managed zone the solver may edit."
  type        = string
}

variable "k8s_namespace" {
  description = "Namespace cert-manager runs in."
  type        = string
  default     = "cert-manager"
}

variable "k8s_service_account" {
  description = "Kubernetes service account cert-manager runs as."
  type        = string
  default     = "cert-manager"
}
