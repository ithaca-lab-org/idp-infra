variable "project_id" {
  description = "GCP project ID (builds the Workload Identity pool name and the default custom role ID)."
  type        = string
}

variable "account_id" {
  description = "Account ID of the Google service account the resource broker runs as."
  type        = string
  default     = "idp-broker"
}

variable "broker_ksa" {
  description = "Kubernetes service account (namespace and name) of the resource broker."
  type        = object({ namespace = string, name = string })
  default     = { namespace = "idp-system", name = "idp-broker" }
}

variable "role_id" {
  description = "Custom role bound to the broker. Created by bootstrap/ (human-applied), not by this module. Null means projects/<project_id>/roles/idpBrokerBuckets."
  type        = string
  default     = null
}

variable "bucket_prefix" {
  description = "Name prefix of the buckets the broker may touch (IAM condition on resource.name). Must end with a dash."
  type        = string
  default     = "idp-"

  validation {
    condition     = endswith(var.bucket_prefix, "-") && length(var.bucket_prefix) > 1
    error_message = "bucket_prefix must end with '-' (so 'idp-' cannot match 'idpfoo') and not be just '-'."
  }
}

variable "menu_roles" {
  description = "The only roles the broker may grant (IAM condition on modifiedGrantsByRole). Only roles/storage.objectViewer and roles/storage.objectUser are accepted."
  type        = list(string)
  default     = ["roles/storage.objectViewer", "roles/storage.objectUser"]

  validation {
    condition     = length(var.menu_roles) > 0 && alltrue([for r in var.menu_roles : contains(["roles/storage.objectViewer", "roles/storage.objectUser"], r)])
    error_message = "menu_roles may only contain roles/storage.objectViewer and roles/storage.objectUser."
  }
}
