output "topic_id" {
  description = "Order events topic ID (short name; portal-api env PUBSUB_TOPIC)."
  value       = google_pubsub_topic.events.name
}

output "subscription_id" {
  description = "Notifier subscription ID (short name; notifier env PUBSUB_SUBSCRIPTION)."
  value       = google_pubsub_subscription.notifier.name
}

output "dead_letter_topic_id" {
  description = "Dead-letter topic (full resource name)."
  value       = google_pubsub_topic.dead_letter.id
}

output "dead_letter_subscription_id" {
  description = "Subscription for inspecting dead-lettered messages (short name)."
  value       = google_pubsub_subscription.dead_letter.name
}

output "publisher_service_account_email" {
  description = "GSA for the portal-api KSA annotation (iam.gke.io/gcp-service-account)."
  value       = google_service_account.publisher.email
}

output "subscriber_service_account_email" {
  description = "GSA for the notifier KSA annotation (iam.gke.io/gcp-service-account)."
  value       = google_service_account.subscriber.email
}

output "resend_secret_id" {
  description = "Secret Manager secret for the Resend API key (no version until a human adds one)."
  value       = google_secret_manager_secret.resend_api_key.secret_id
}
