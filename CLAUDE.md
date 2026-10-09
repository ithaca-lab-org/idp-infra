# idp-infra rules

Part of the ithaca IDP. Architecture and decisions live in `../IDP_NOTES.md` (sections 1, 4, 11).

- GCP project `project-324502ff-9928-4b17-a89`, region `us-central1`, zone `us-central1-a`. Budget-first.
- GKE **Standard, zonal**, one **Spot e2-standard-4** pool. Never create Autopilot or regional clusters.
- Terraform >= 1.9, `google` provider pinned in `versions.tf`. Remote state in GCS bucket `project-324502ff-9928-4b17-a89-tfstate` (prefix per stack).
- Every module has `variables.tf`, `outputs.tf`, `README.md`. Before finishing any change run `make check` (fmt, validate, tflint, checkov).
- **NEVER run `terraform apply` or `destroy`, `kubectl delete`, or `gcloud ... delete`.** Produce a plan and stop. A human or CI applies.
- No service-account JSON keys, ever. CI uses Workload Identity Federation; pods use Workload Identity.
- `bootstrap/` is applied once by a human from a laptop. CI only runs `envs/*`.
- Keep the state bucket and Artifact Registry outside anything `make down` destroys.
- Changes go through a PR to `main`; `main` applies automatically. Use conventional commits.
- No secrets, passwords or account IDs in docs or code that don't already appear in tfvars. Never commit `idp_details.rtf`.
