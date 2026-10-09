resource "google_dns_managed_zone" "this" {
  name        = replace(trimsuffix(var.domain, "."), ".", "-")
  dns_name    = "${trimsuffix(var.domain, ".")}."
  description = "Public zone for the IDP demo domain."

  dnssec_config {
    state = "on"
  }
}
