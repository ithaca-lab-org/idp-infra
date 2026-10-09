# One-time bootstrap: run from a laptop with user credentials, then migrate
# state into the bucket it creates. Everything after this runs from GitHub
# Actions via Workload Identity Federation -- no service-account keys exist.

locals {
  state_bucket_name = "${var.project_id}-tfstate"
  wif_pool_root     = "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}"
  infra_repo_full   = "${var.github_org}/${var.infra_repo}"
}

# --- APIs -------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset(var.enabled_apis)

  service            = each.value
  disable_on_destroy = false
}

# --- Terraform state bucket -------------------------------------------------

resource "google_storage_bucket" "tfstate" {
  # checkov:skip=CKV_GCP_62:Access logging on the state bucket is not worth the cost for a single-user lab; Cloud Audit Logs cover data access.
  name                        = local.state_bucket_name
  location                    = var.state_bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  # Keep the last 10 versions of each state file; drop older ones after 30 days.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# --- Workload Identity Federation for GitHub Actions ------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for GitHub Actions in ${var.github_org}"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125:Pool is org-scoped by design (sample-app repos share it); per-repo/ref restriction is enforced on each SA's workloadIdentityUser binding.
  # checkov:skip=CKV_GCP_118:attribute_condition is set; checkov cannot evaluate the interpolated expression.
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.repository_ref"   = "assertion.repository + '@' + assertion.ref"
  }

  # Reject tokens from any other GitHub org. The numeric ID is immutable, so a
  # re-registered org name can't mint tokens; the name check keeps it readable.
  attribute_condition = "assertion.repository_owner_id == '${var.github_org_id}' && assertion.repository_owner == '${var.github_org}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- CI service accounts ----------------------------------------------------
# Two identities: PRs can only plan (read-only); only main can apply.

resource "google_service_account" "terraform_plan" {
  account_id   = "terraform-plan"
  display_name = "Terraform plan (GitHub Actions, PRs)"
  description  = "Read-only identity used by ${local.infra_repo_full} pull requests."
}

resource "google_service_account" "terraform_apply" {
  account_id   = "terraform-apply"
  display_name = "Terraform apply (GitHub Actions, ${var.apply_ref})"
  description  = "Write identity used by ${local.infra_repo_full} on ${var.apply_ref} only."
}

resource "google_project_iam_member" "plan" {
  for_each = toset(var.plan_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform_plan.member
}

resource "google_project_iam_member" "apply" {
  # checkov:skip=CKV_GCP_41:GKE node pools must attach a node service account created by the same stack; scoped by the main-only WIF binding.
  # checkov:skip=CKV_GCP_49:Same as above -- the apply SA creates and attaches workload/node service accounts.
  for_each = toset(var.apply_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform_apply.member
}

resource "google_billing_account_iam_member" "apply_costs_manager" {
  count = var.billing_account_id == null ? 0 : 1

  billing_account_id = var.billing_account_id
  role               = "roles/billing.costsManager"
  member             = google_service_account.terraform_apply.member
}

# State access is granted on the bucket only, not project-wide storage.
# Plan needs object write too, because `terraform plan` takes a state lock.
resource "google_storage_bucket_iam_member" "plan_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = google_service_account.terraform_plan.member
}

resource "google_storage_bucket_iam_member" "apply_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = google_service_account.terraform_apply.member
}

# Any workflow in the infra repo may impersonate the plan SA...
resource "google_service_account_iam_member" "plan_wif" {
  service_account_id = google_service_account.terraform_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool_root}/attribute.repository/${local.infra_repo_full}"
}

# ...but only workflows on the protected apply ref may impersonate the apply SA.
resource "google_service_account_iam_member" "apply_wif" {
  service_account_id = google_service_account.terraform_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool_root}/attribute.repository_ref/${local.infra_repo_full}@${var.apply_ref}"
}
