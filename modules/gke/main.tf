locals {
  # Google's purpose-built node role (logging, monitoring, autoscaling metrics,
  # resource metadata). Registry read access is granted per repository in envs/dev.
  node_sa_roles = ["roles/container.defaultNodeServiceAccount"]
}

# Dedicated least-privilege node identity (never the default Compute SA).
resource "google_service_account" "nodes" {
  account_id   = "${var.name}-nodes"
  display_name = "GKE nodes (${var.name})"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset(local.node_sa_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "this" {
  # checkov:skip=CKV_GCP_24:PodSecurityPolicy is removed from GKE; Pod Security Admission and Kyverno enforce policy instead (Step 6 / Phase 4).
  # checkov:skip=CKV_GCP_25:Zonal by design (free-tier management fee, see IDP_NOTES section 4); public endpoint is kept off the allowlist path: CI and laptops use the IAM-gated DNS endpoint (control_plane_endpoints_config).
  # checkov:skip=CKV_GCP_66:Binary Authorization is replaced by Cosign + Kyverno admission verification (Phase 5).
  # checkov:skip=CKV_GCP_69:Workload Identity (GKE_METADATA) is enabled on the node pool; checkov cannot see it across resources.
  # checkov:skip=CKV_GCP_12:Network policy is enforced by Dataplane V2 (ADVANCED_DATAPATH), not the legacy Calico addon.
  # checkov:skip=CKV_GCP_61:Intranode visibility turns on flow logs for all pod traffic, which adds Logging cost; Dataplane V2 network policy covers the isolation need.
  # checkov:skip=CKV_GCP_65:Google Groups RBAC needs a Workspace/Cloud Identity group; single-user lab uses IAM-bound users.
  name     = var.name
  location = var.zone

  # Cheap, quick teardown. `make down` must be able to destroy the cluster.
  deletion_protection = false

  network    = var.network_id
  subnetwork = var.subnetwork_id

  # The default pool is replaced by the managed Spot pool below. It still boots
  # briefly, so give it the dedicated node identity instead of the default
  # Compute service account.
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # GKE reports spot = true at the cluster level once the default pool is
    # removed (it mirrors the remaining Spot pool). Leaving this false makes
    # every plan try to replace the cluster.
    spot = true

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  # Turn off the unauthenticated kubelet read-only port (10255) on all pools.
  node_pool_defaults {
    node_config_defaults {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  # IAM-gated DNS endpoint: reachable from laptops and CI without IP allowlists.
  # Use `gcloud container clusters get-credentials --dns-endpoint`.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = var.kms_key_id
  }

  # Keep telemetry to system components to hold Logging/Monitoring cost down.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  maintenance_policy {
    recurring_window {
      # GKE requires >= 48h of maintenance availability in any rolling 32 days.
      # 4h daily is ~128h; weekend-only 4h windows would be ~36h and fail.
      start_time = "2026-01-01T08:00:00Z"
      end_time   = "2026-01-01T12:00:00Z"
      recurrence = "FREQ=DAILY"
    }
  }

  resource_labels = var.labels

  depends_on = [google_project_iam_member.nodes]
}

resource "google_container_node_pool" "spot" {
  name     = "spot"
  cluster  = google_container_cluster.this.id
  location = var.zone

  initial_node_count = var.initial_node_count

  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    spot            = true
    disk_type       = "pd-balanced"
    disk_size_gb    = var.disk_size_gb
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# The control plane reaches nodes only on 443/10250 by default. Admission
# webhooks (istiod 15017, Kyverno 9443) need explicit access from the master range.
resource "google_compute_firewall" "master_webhooks" {
  name      = "${var.name}-master-webhooks"
  network   = var.network_id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = [var.master_cidr]

  allow {
    protocol = "tcp"
    ports    = ["15017", "9443"]
  }
}
