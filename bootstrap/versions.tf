terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Bill API quota to this project, not the shared default project of the gcloud login (that quota
  # is shared with other users and returns 429 RATE_LIMIT_EXCEEDED). Same as envs/persistent.
  user_project_override = true
  billing_project       = var.project_id
}
