terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
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
