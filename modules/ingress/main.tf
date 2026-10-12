# Static IP for the Istio ingress gateway plus a wildcard record that points at it.
# Both live in the persistent stack, so the address and DNS survive `make down`
# and nothing has to change in DNS when the cluster is rebuilt.
resource "google_compute_address" "ingress" {
  name         = var.name
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Istio ingress gateway (apps.${trimsuffix(var.domain, ".")})"
}

resource "google_dns_record_set" "apps_wildcard" {
  managed_zone = var.zone_name
  name         = "*.apps.${trimsuffix(var.domain, ".")}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.ingress.address]
}
