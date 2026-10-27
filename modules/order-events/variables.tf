variable "project_id" {
  description = "GCP project ID (builds the Workload Identity pool name)."
  type        = string
}

variable "project_number" {
  description = "GCP project number (builds the Pub/Sub service agent address)."
  type        = string
}

variable "topic_name" {
  description = "Order events topic. The dead-letter topic and its subscription are named <topic>-dead-letter."
  type        = string
  default     = "order-events"
}

variable "subscription_name" {
  description = "Pull subscription the notifier consumes."
  type        = string
  default     = "order-events-notifier"
}

variable "ack_deadline_seconds" {
  description = "Ack deadline for the subscriptions."
  type        = number
  default     = 60
}

variable "message_retention_duration" {
  description = "How long unacknowledged messages are kept on each subscription (bounded; max 7 days)."
  type        = string
  default     = "604800s"
}

variable "retry_minimum_backoff" {
  description = "Minimum redelivery backoff after a nack or ack deadline expiry."
  type        = string
  default     = "10s"
}

variable "retry_maximum_backoff" {
  description = "Maximum redelivery backoff."
  type        = string
  default     = "300s"
}

variable "max_delivery_attempts" {
  description = "Delivery attempts before a message moves to the dead-letter topic (5 to 100)."
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "Pub/Sub allows 5 to 100 delivery attempts."
  }
}

variable "publisher_account_id" {
  description = "Account ID of the Google service account portal-api runs as."
  type        = string
  default     = "portal-api"
}

variable "subscriber_account_id" {
  description = "Account ID of the Google service account the notifier runs as."
  type        = string
  default     = "notifier"
}

variable "publisher_ksa" {
  description = "Kubernetes service account (namespace and name) that publishes order events."
  type        = object({ namespace = string, name = string })
  default     = { namespace = "idp-system", name = "portal-api" }
}

variable "subscriber_ksa" {
  description = "Kubernetes service account (namespace and name) of the notifier."
  type        = object({ namespace = string, name = string })
  default     = { namespace = "idp-system", name = "notifier" }
}

variable "labels" {
  description = "Labels for the topics and subscriptions."
  type        = map(string)
  default     = { app = "order-events", stack = "idp" }
}
