resource "google_artifact_registry_repository" "this" {
  # checkov:skip=CKV_GCP_84:Google-managed encryption is enough for lab images; CMEK would add KMS cost and an IAM dependency.
  repository_id = var.repository_id
  location      = var.location
  format        = "DOCKER"
  description   = "Container images for the IDP and its sample apps."

  cleanup_policy_dry_run = false

  # Keep the 10 newest versions of every package, whatever their age...
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  # ...drop untagged layers after a week and anything else after 30 days.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "2592000s"
    }
  }
}
