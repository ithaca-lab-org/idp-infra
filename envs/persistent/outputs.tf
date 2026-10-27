output "registry_url" {
  description = "Docker registry URL prefix."
  value       = module.registry.url
}

output "name_servers" {
  description = "Set these as custom nameservers at Squarespace."
  value       = module.dns.name_servers
}

output "ds_record" {
  description = "DNSSEC DS record for the registrar."
  value       = module.dns.ds_record
}

output "ingress_ip" {
  description = "Reserved IP for the Istio ingress gateway (*.apps.<domain> points here)."
  value       = module.ingress.ip_address
}

output "cert_manager_dns01_sa" {
  description = "Google service account for cert-manager's DNS-01 solver."
  value       = module.cert_manager_dns.service_account_email
}

output "order_events_topic_id" {
  description = "Order events topic (portal-api env PUBSUB_TOPIC)."
  value       = module.order_events.topic_id
}

output "order_events_subscription_id" {
  description = "Notifier subscription (notifier env PUBSUB_SUBSCRIPTION)."
  value       = module.order_events.subscription_id
}

output "order_events_dead_letter_subscription_id" {
  description = "Subscription for inspecting dead-lettered order events."
  value       = module.order_events.dead_letter_subscription_id
}

output "portal_api_sa" {
  description = "Google service account for the idp-system/portal-api KSA annotation."
  value       = module.order_events.publisher_service_account_email
}

output "notifier_sa" {
  description = "Google service account for the idp-system/notifier KSA annotation."
  value       = module.order_events.subscriber_service_account_email
}

output "resend_secret_id" {
  description = "Secret Manager secret for the Resend API key (empty until a human adds a version)."
  value       = module.order_events.resend_secret_id
}
