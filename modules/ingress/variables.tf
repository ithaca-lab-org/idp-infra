variable "name" {
  description = "Name of the reserved address."
  type        = string
  default     = "idp-ingress"
}

variable "region" {
  description = "Region of the address; must match the cluster's region."
  type        = string
}

variable "domain" {
  description = "Base domain, e.g. ithaca-idp.com. Apps are served at *.apps.<domain>."
  type        = string
}

variable "zone_name" {
  description = "Cloud DNS managed zone that holds the wildcard record."
  type        = string
}
