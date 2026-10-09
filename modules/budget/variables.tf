variable "billing_account_id" {
  description = "Billing account ID."
  type        = string
}

variable "project_number" {
  description = "Project number the budget is scoped to."
  type        = string
}

variable "display_name" {
  description = "Budget name."
  type        = string
  default     = "idp-monthly"
}

variable "amount_usd" {
  description = "Monthly budget in USD."
  type        = number
  default     = 50
}

variable "thresholds" {
  description = "Actual-spend alert thresholds as fractions of the budget."
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
}
