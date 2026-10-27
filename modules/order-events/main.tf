# Order events: portal-api publishes JSON order events, the notifier pulls them and (when
# NOTIFIER_SEND_EMAIL=true) sends email through Resend. Persistent on purpose: nothing here
# refers to the cluster except the Workload Identity bindings, which name the project's
# identity pool and a namespace/KSA, so they survive `make down` (like cert-manager-dns).
# No project-level roles anywhere: every grant is on one topic, subscription or service account.

locals {
  wi_pool      = "${var.project_id}.svc.id.goog"
  pubsub_agent = "serviceAccount:service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# --- Topics ------------------------------------------------------------------

resource "google_pubsub_topic" "events" {
  # checkov:skip=CKV_GCP_83:Google-managed encryption; a CMEK key per topic adds cost and a KMS grant for a lab with no sensitive payloads (order metadata only).
  name   = var.topic_name
  labels = var.labels
}

resource "google_pubsub_topic" "dead_letter" {
  # checkov:skip=CKV_GCP_83:Same as the events topic.
  name   = "${var.topic_name}-dead-letter"
  labels = var.labels
}

# --- Subscriptions -----------------------------------------------------------

resource "google_pubsub_subscription" "notifier" {
  name   = var.subscription_name
  topic  = google_pubsub_topic.events.id
  labels = var.labels

  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = var.message_retention_duration
  retain_acked_messages      = false

  retry_policy {
    minimum_backoff = var.retry_minimum_backoff
    maximum_backoff = var.retry_maximum_backoff
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  # The default policy deletes a subscription after 31 days without a subscriber. The notifier
  # is absent whenever the cluster is down, so never expire (Terraform would recreate it anyway).
  expiration_policy {
    ttl = ""
  }
}

# Messages published to a topic with no subscription are dropped, so the dead-letter topic gets
# one pull subscription to inspect failures from a laptop (`gcloud pubsub subscriptions pull`).
# No workload is granted access to it.
resource "google_pubsub_subscription" "dead_letter" {
  name   = "${var.topic_name}-dead-letter"
  topic  = google_pubsub_topic.dead_letter.id
  labels = var.labels

  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = var.message_retention_duration
  retain_acked_messages      = false

  expiration_policy {
    ttl = ""
  }
}

# Dead-lettering is done by the Pub/Sub service agent: it must publish to the dead-letter topic
# and acknowledge (subscribe) on the source subscription. Granted on exactly those two resources.
resource "google_pubsub_topic_iam_member" "agent_dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "agent_source_subscriber" {
  subscription = google_pubsub_subscription.notifier.id
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# --- Workload identities -----------------------------------------------------

resource "google_service_account" "publisher" {
  account_id   = var.publisher_account_id
  display_name = "portal-api (order events publisher)"
  description  = "Workload Identity for ${var.publisher_ksa.namespace}/${var.publisher_ksa.name}. Publish on ${var.topic_name} only; no project roles."
}

resource "google_service_account" "subscriber" {
  account_id   = var.subscriber_account_id
  display_name = "notifier (order events subscriber)"
  description  = "Workload Identity for ${var.subscriber_ksa.namespace}/${var.subscriber_ksa.name}. Consume ${var.subscription_name} only; no project roles."
}

# pubsub v2 Publisher.Publish and Subscriber.Receive need no get/viewer permission (no
# existence checks; subscription properties come back on the streaming pull itself).
resource "google_pubsub_topic_iam_member" "publisher" {
  topic  = google_pubsub_topic.events.id
  role   = "roles/pubsub.publisher"
  member = google_service_account.publisher.member
}

resource "google_pubsub_subscription_iam_member" "subscriber" {
  subscription = google_pubsub_subscription.notifier.id
  role         = "roles/pubsub.subscriber"
  member       = google_service_account.subscriber.member
}

resource "google_service_account_iam_member" "publisher_wi" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.publisher_ksa.namespace}/${var.publisher_ksa.name}]"
}

resource "google_service_account_iam_member" "subscriber_wi" {
  service_account_id = google_service_account.subscriber.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.subscriber_ksa.namespace}/${var.subscriber_ksa.name}]"
}

# --- Resend API key ------------------------------------------------------------
# The secret container only: no version, so no value ever reaches Terraform state. A human
# adds the version (docs/order-events.md); scripts/bootstrap-secrets.sh copies it into the
# cluster when it exists and skips it otherwise. No IAM here: the notifier never reads Secret
# Manager itself (same pattern as the other bootstrap secrets, ADR 0005).
resource "google_secret_manager_secret" "resend_api_key" {
  secret_id = var.resend_secret_id
  labels    = var.labels

  replication {
    auto {}
  }

  # Deleting the container would delete the human-added version with it.
  deletion_protection = true
}
