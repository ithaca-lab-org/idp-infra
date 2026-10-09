variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "name" {
  description = "Cluster name; also prefixes the node service account."
  type        = string
}

variable "zone" {
  description = "Zone for the zonal cluster."
  type        = string
}

variable "network_id" {
  description = "VPC network ID."
  type        = string
}

variable "subnetwork_id" {
  description = "Node subnetwork ID."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services."
  type        = string
}

variable "kms_key_id" {
  description = "Crypto key ID for application-layer secrets encryption."
  type        = string
}

variable "master_cidr" {
  description = "/28 for the control plane's private range. Must not overlap the VPC."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = "Map of display name to CIDR allowed to reach the public API endpoint, e.g. { laptop = \"203.0.113.7/32\" }. Empty means nobody outside Google's control plane."
  type        = map(string)
  default     = {}
}

variable "machine_type" {
  description = "Spot pool machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Node boot disk size."
  type        = number
  default     = 50
}

variable "initial_node_count" {
  description = "Nodes at creation. The autoscaler takes over afterwards."
  type        = number
  default     = 2
}

variable "min_nodes" {
  description = "Autoscaler minimum (0 lets the pool scale to zero overnight)."
  type        = number
  default     = 0
}

variable "max_nodes" {
  description = "Autoscaler maximum."
  type        = number
  default     = 4
}

variable "labels" {
  description = "Labels applied to the cluster and nodes."
  type        = map(string)
  default     = {}
}
