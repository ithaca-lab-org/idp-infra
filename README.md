# idp-infra

Terraform for the ithaca Internal Developer Platform on GKE (Standard, zonal, Spot). See `CLAUDE.md` for the working rules and `docs/adr/` for decisions.

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time stack: APIs, state bucket, GitHub OIDC federation, plan/apply service accounts |
| `modules/` | `network`, `gke`, `registry`, `dns`, `budget` (added in Phase 0, Step 5) |
| `envs/dev/` | The environment CI plans on PRs and applies on merge to `main` |

## CI

- **Pull request:** fmt, validate, tflint, checkov, then `terraform plan` as the read-only `terraform-plan` service account; the plan is posted as a PR comment.
- **Merge to `main`:** `terraform apply` as `terraform-apply`, which only federation from `refs/heads/main` can use.

Required repository **variables** (not secrets; no keys exist): `GCP_WIF_PROVIDER`, `GCP_PLAN_SA`, `GCP_APPLY_SA`. Values come from `terraform output` in `bootstrap/`.

## Repo hygiene

| Practice | Where |
|---|---|
| Protected `main`, squash-only, linear history, required checks (as code) | `.github/rulesets/main.json`, `scripts/apply-repo-settings.sh` |
| Conventional commits (local hook and PR-title check) -> automatic versions, tags, `CHANGELOG.md` | `pr-title.yml`, `release.yml` (release-please) |
| Least-privilege workflows, every action pinned to a commit SHA, zizmor + CodeQL on workflows | `.github/workflows/` |
| Keyless cloud auth, plan/apply identity split | `bootstrap/`, `pr.yml`, `apply.yml` |
| Dependency updates (Actions, Terraform) and dependency review | `dependabot.yml`, `dependency-review.yml` |
| Supply-chain score | `scorecard.yml` (OpenSSF Scorecard) |
| Secret scanning: gitleaks hook, GitHub push protection | `.pre-commit-config.yaml`, settings script |
| Ownership, templates, security policy, license, ADRs | `CODEOWNERS`, `.github/`, `SECURITY.md`, `LICENSE`, `docs/adr/` |

## Local

```bash
pre-commit install --install-hooks && pre-commit install --hook-type commit-msg
make check
make plan
```
