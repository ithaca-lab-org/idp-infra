variable "project_id" {
  description = "GCP project ID that hosts the IDP."
  type        = string
}

variable "project_number" {
  description = "GCP project number."
  type        = string
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Default zone."
  type        = string
  default     = "us-central1-a"
}

variable "domain" {
  description = "Demo domain managed in Cloud DNS."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account ID for the budget."
  type        = string
}

variable "budget_usd" {
  description = "Monthly budget in USD."
  type        = number
  default     = 50
}
