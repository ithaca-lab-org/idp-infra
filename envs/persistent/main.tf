# Long-lived resources that `make down` must never touch. CI applies this stack
# on merge to main. The destroyable cluster lives in envs/dev.

module "kms" {
  source = "../../modules/kms"

  project_number = var.project_number
  location       = var.region
}

module "registry" {
  source = "../../modules/registry"

  location = var.region
}

module "dns" {
  source = "../../modules/dns"

  domain = var.domain
}

module "ingress" {
  source = "../../modules/ingress"

  region    = var.region
  domain    = var.domain
  zone_name = module.dns.zone_name
}

module "cert_manager_dns" {
  source = "../../modules/cert-manager-dns"

  project_id = var.project_id
  zone_name  = module.dns.zone_name
}

module "budget" {
  source = "../../modules/budget"

  billing_account_id = var.billing_account_id
  project_number     = var.project_number
  amount_usd         = var.budget_usd
}

# Order events pipeline (portal-api -> Pub/Sub -> notifier). Persistent: topics, subscriptions,
# service accounts and their Workload Identity bindings do not depend on the cluster, queued
# events survive `make down`, and idle cost is zero. See docs/order-events.md.
module "order_events" {
  source = "../../modules/order-events"

  project_id     = var.project_id
  project_number = var.project_number
}

# Vault auto-unseal (seal "gcpckms"): key vault-unseal in the existing ring, GSA vault with
# grants on that key only, Workload Identity for vault/vault. See docs/vault.md.
module "vault_unseal" {
  source = "../../modules/vault-unseal"

  project_id  = var.project_id
  key_ring_id = module.kms.key_ring_id
}
