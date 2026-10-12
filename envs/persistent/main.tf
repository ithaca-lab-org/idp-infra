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
