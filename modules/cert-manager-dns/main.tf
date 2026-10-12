# Identity cert-manager uses for Let's Encrypt DNS-01 challenges in Cloud DNS.
# Persistent on purpose: only the Workload Identity binding refers to the
# cluster, by pool and namespace/service account, so it survives rebuilds.
resource "google_service_account" "dns01" {
  account_id   = "cert-manager-dns01"
  display_name = "cert-manager DNS-01 solver"
}

# Scoped to the one zone, not the project.
resource "google_dns_managed_zone_iam_member" "dns01" {
  managed_zone = var.zone_name
  role         = "roles/dns.admin"
  member       = google_service_account.dns01.member
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.dns01.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_service_account}]"
}
