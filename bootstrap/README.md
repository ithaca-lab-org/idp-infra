# bootstrap

One-time stack that creates what every other stack depends on. It runs once from a laptop and is never destroyed by `make down`.

| Resource | Purpose |
|---|---|
| `google_project_service.apis` | Enables every API the IDP uses, once, so later stacks never toggle services |
| `google_storage_bucket.tfstate` | Versioned, private GCS bucket for all Terraform state (`prevent_destroy`) |
| WIF pool `github` + provider `github-actions` | GitHub Actions OIDC; tokens from any other org (matched by numeric org ID) are rejected |
| SA `terraform-plan` | Read-only. Any workflow in `idp-infra` can use it (PR plans) |
| SA `terraform-apply` | Scoped write roles, no Owner/Editor. Only workflows on `refs/heads/main` can use it |

No service-account keys are created. CI authenticates with `google-github-actions/auth` using the outputs.

## Run once

```bash
gcloud config set account <your-google-account>
export TF_VAR_billing_account_id=<billing-account-id>   # not committed
gcloud auth application-default login
gcloud config set project project-324502ff-9928-4b17-a89

terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan

# Move state into the bucket that was just created
mv backend.tf.example backend.tf
terraform init -migrate-state
rm -f terraform.tfstate terraform.tfstate.backup
```

## Outputs used by CI

```bash
terraform output -raw workload_identity_provider   # -> GitHub var GCP_WIF_PROVIDER
terraform output -raw plan_service_account         # -> GitHub var GCP_PLAN_SA
terraform output -raw apply_service_account        # -> GitHub var GCP_APPLY_SA
terraform output -raw state_bucket                 # -> backend bucket for envs/dev
```

## Design notes

- **Plan/apply split.** PRs get a read-only identity, so a malicious PR can't change infrastructure. Only the protected `main` branch can apply.
- **Org ID, not name.** The provider condition uses `repository_owner_id` so a renamed/re-registered org name can't mint tokens.
- **State bucket IAM is bucket-scoped.** CI SAs have `storage.objectUser` on this bucket only, not project-wide storage access.
- **`projectIamAdmin` on the apply SA** is the most powerful role here. It is needed so stacks can bind Workload Identity for pods. A production setup would narrow it with an IAM condition or a dedicated project per environment.
