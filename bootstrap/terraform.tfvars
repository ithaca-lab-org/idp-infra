project_id     = "project-324502ff-9928-4b17-a89"
project_number = "278184209873"
region         = "us-central1"

github_org    = "ithaca-lab-org"
github_org_id = "338867720"

# billing_account_id is intentionally not committed. Export it before plan/apply:
#   export TF_VAR_billing_account_id=<your billing account ID>
# Without it, Terraform plans to remove the apply SA's billing.costsManager grant.
