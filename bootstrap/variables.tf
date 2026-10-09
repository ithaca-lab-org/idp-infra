variable "project_id" {
  description = "GCP project ID that hosts the IDP."
  type        = string
}

variable "project_number" {
  description = "GCP project number (used to build WIF principal URIs)."
  type        = string
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_location" {
  description = "Location of the Terraform state bucket. A single region keeps cost down."
  type        = string
  default     = "US-CENTRAL1"
}

variable "github_org" {
  description = "GitHub organization that owns the IDP repos."
  type        = string
}

variable "github_org_id" {
  description = "Numeric GitHub organization ID. Pinning the ID (not the name) prevents org-name squatting."
  type        = string
}

variable "infra_repo" {
  description = "Repository (without org) whose GitHub Actions run Terraform."
  type        = string
  default     = "idp-infra"
}

variable "apply_ref" {
  description = "Only workflows running on this git ref may impersonate the apply service account."
  type        = string
  default     = "refs/heads/main"
}

variable "enabled_apis" {
  description = "GCP APIs the platform needs. Enabled once here so later stacks never toggle services."
  type        = list(string)
  default = [
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

variable "apply_roles" {
  description = "Project roles for the apply service account. Scoped to the services the IDP stacks manage; no Owner/Editor."
  type        = list(string)
  default = [
    "roles/artifactregistry.admin",
    "roles/cloudkms.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/pubsub.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

variable "plan_roles" {
  description = "Project roles for the read-only plan service account used on pull requests. Per-service viewers instead of roles/viewer."
  type        = list(string)
  default = [
    "roles/artifactregistry.reader",
    "roles/browser",
    "roles/cloudkms.viewer",
    "roles/compute.viewer",
    "roles/container.viewer",
    "roles/dns.reader",
    "roles/iam.securityReviewer",
    "roles/iam.serviceAccountViewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/pubsub.viewer",
    "roles/secretmanager.viewer",
    "roles/serviceusage.serviceUsageViewer",
  ]
}

variable "billing_account_id" {
  description = "Billing account ID. When set, the apply SA gets billing.costsManager so Terraform can own the budget alert (Step 5). Requires you to be a billing admin."
  type        = string
  default     = null
}
