# Identity of the in-cluster resource broker (ADR 0010): creates tenant buckets named idp-* and
# sets IAM on them. Persistent stack, CI-applied. The broker's one project-level grant uses a
# custom role that bootstrap/ creates (human-applied, CI has no roles/iam.roleAdmin on purpose),
# so bootstrap must be applied first: the plan does not check the role, but the apply of the binding
# below fails with "role does not exist" and keeps every later persistent apply red.
# No project-level storage roles and no storage.objects.* permission anywhere.

locals {
  wi_pool = "${var.project_id}.svc.id.goog"
  role_id = coalesce(var.role_id, "projects/${var.project_id}/roles/idpBrokerBuckets")

  # Both halves must hold for the binding to apply:
  #  - resource.name: the call targets a bucket whose name starts with the prefix. Bucket
  #    create and setIamPolicy are evaluated against projects/_/buckets/<name>.
  #  - modifiedGrantsByRole: any IAM policy change made with this grant may only add or remove
  #    the menu roles. The spike proved this limit with the predefined roles/storage.admin; it is NOT
  #    yet proven with this custom role (the proof script checks after the apply). It limits roles,
  #    not members and not bucket settings: see the org policy guardrails in docs/tenant-resources.md.
  menu_list            = join(", ", formatlist("'%s'", var.menu_roles))
  condition_expression = "resource.name.startsWith(\"projects/_/buckets/${var.bucket_prefix}\") && api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([${local.menu_list}])"
}

resource "google_service_account" "broker" {
  account_id   = var.account_id
  display_name = "idp-broker (tenant bucket broker)"
  description  = "Workload Identity for ${var.broker_ksa.namespace}/${var.broker_ksa.name}. Creates and manages ${var.bucket_prefix}* buckets and their IAM, menu roles only; no object access. ADR 0010."
}

resource "google_service_account_iam_member" "broker_wi" {
  service_account_id = google_service_account.broker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${var.broker_ksa.namespace}/${var.broker_ksa.name}]"
}

resource "google_project_iam_member" "broker_buckets" {
  # checkov:skip=CKV_GCP_49:Custom bucket-only role (no impersonation permissions), restricted by an IAM condition to prefix-named buckets and menu roles.
  project = var.project_id
  role    = local.role_id
  member  = google_service_account.broker.member

  condition {
    title       = "idp-buckets-and-menu-roles"
    description = "Only buckets named ${var.bucket_prefix}*, and IAM changes limited to ${join(", ", var.menu_roles)} (ADR 0010)."
    expression  = local.condition_expression
  }
}
