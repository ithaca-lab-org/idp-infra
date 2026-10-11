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
}
