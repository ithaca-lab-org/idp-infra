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
- Bootstrap secrets (the Tailscale operator OAuth client, and the generated identity secrets, see `docs/identity.md`) live in Google Secret Manager and are copied into the cluster by `scripts/bootstrap-secrets.sh` during `make up` (ADR 0005, `docs/tailscale.md`). Never read, print or log their values, and never put them in Terraform state.
- Changes go through a PR to `main`. Use conventional commits.
- A Terraform change that needs a role or resource from `bootstrap/` (human-applied) must wait: the human applies `bootstrap/` FIRST, then the PR merges; otherwise the PR plan is green but the CI apply on `main` fails and every later persistent apply stays red (idp-infra #45). Say so in the PR body.
- Add files to commits by name, never `git add -A`: untracked `.terraform.lock.hcl` files under `modules/` must stay out. Never use `rm -rf`; if the pre-commit `terraform validate` reports "Module not installed", `mv` the stale `envs/<stack>/.terraform` aside, run `terraform init -backend=false` there, commit, and move it back.
- Scripts that delete or change cloud state (`*-cleanup.sh`, `*-proof.sh`, `set-tenant-org-policies.sh`) are run by the human, never by the agent; they are dry-run or confirm-first by design.
- No secrets, passwords or account IDs in docs or code that don't already appear in tfvars. Never commit `idp_details.rtf`.
