terraform {
  backend "gcs" {
    bucket = "project-324502ff-9928-4b17-a89-tfstate"
    prefix = "bootstrap"
  }
}
