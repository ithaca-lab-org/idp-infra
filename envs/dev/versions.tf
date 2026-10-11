terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }

  backend "gcs" {
    bucket = "project-324502ff-9928-4b17-a89-tfstate"
    prefix = "envs/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Reaches the cluster through its IAM-gated DNS endpoint with the caller's own
# credentials, so no kubeconfig or IP allowlist is needed to install Argo CD.
data "google_client_config" "default" {}

provider "helm" {
  kubernetes = {
    host  = "https://${module.gke.dns_endpoint}"
    token = data.google_client_config.default.access_token
  }
}
