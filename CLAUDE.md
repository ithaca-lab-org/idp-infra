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
- Two stacks: `envs/persistent` (KMS, registry, DNS, budget) is applied by CI on merge; `envs/dev` (network, GKE) is human-only via `make up` / `make down` (ADR 0004).
- Terraform installs Argo CD only (`modules/argocd`); add-ons live in the `idp-gitops` repo (ADR 0003). Do not add more `helm_release` resources here beyond the Argo CD pair (`argo-cd` + `argocd-apps` root app).
- Bootstrap secrets (today only the Tailscale operator OAuth client) live in Google Secret Manager and are copied into the cluster by `scripts/bootstrap-secrets.sh` during `make up` (ADR 0005, `docs/tailscale.md`). Never read, print or log their values, and never put them in Terraform state.
- Changes go through a PR to `main`. Use conventional commits.
- No secrets, passwords or account IDs in docs or code that don't already appear in tfvars. Never commit `idp_details.rtf`.
