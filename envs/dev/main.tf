# Destroyable stack: `make up` builds it, `make down` removes it. Long-lived
# pieces (KMS, registry, DNS, budget) live in envs/persistent.

data "google_kms_crypto_key" "gke_secrets" {
  name     = "gke-secrets"
  key_ring = "projects/${var.project_id}/locations/${var.region}/keyRings/idp"
}

module "network" {
  source = "../../modules/network"

  name   = "idp"
  region = var.region
}

module "gke" {
  source = "../../modules/gke"

  project_id          = var.project_id
  name                = "idp"
  zone                = var.zone
  network_id          = module.network.network_id
  subnetwork_id       = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  kms_key_id          = data.google_kms_crypto_key.gke_secrets.id
  authorized_networks = var.authorized_networks
  labels              = { env = "dev", stack = "idp" }
}
