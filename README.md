# idp-infra

Terraform for the ithaca Internal Developer Platform on GKE (Standard, zonal, Spot). See `CLAUDE.md` for the working rules and `docs/adr/` for decisions.

| Path | Purpose |
|---|---|
| `bootstrap/` | One-time stack, applied by a human: APIs, state bucket, GitHub OIDC federation, plan/apply service accounts, the custom role `idpBrokerBuckets` |
| `modules/` | `network`, `gke`, `kms`, `registry`, `dns`, `budget`, `argocd`, `cert-manager-dns`, `ingress`, `order-events`, `vault-unseal`, `tenant-resources` |
| `envs/persistent/` | Survives `make down`: KMS, registry, DNS, ingress IP, budget, order events, Vault unseal key, the resource broker's service account. **Applied by CI** on merge to `main` (ADR 0004) |
| `envs/dev/` | The destroyable platform (network, GKE, Argo CD). **Human only**: `make up` / `make down` |
| `scripts/` | `verify.sh` (post-build checks), `vault-proof.sh` and `resource-proof.sh` (proofs against the real cluster and project), cleanup scripts (`tailscale-cleanup.sh`, `tenant-resources-cleanup.sh`, `pv-disk-cleanup.sh`), `bootstrap-secrets.sh`, `set-tenant-org-policies.sh`, `precheck.sh`, spikes |
| `docs/` | Operator docs (`vault.md`, `identity.md`, `tailscale.md`, `order-events.md`, `tenant-resources.md`) and `docs/adr/` (decisions 0001 to 0010) |

## CI

- **Pull request:** fmt, validate, tflint, checkov, then `terraform plan` as the read-only `terraform-plan` service account; the plan is posted as a PR comment.
- **Merge to `main`:** `terraform apply` of `envs/persistent` as `terraform-apply`, which only federation from `refs/heads/main` can use. `bootstrap/` and `envs/dev/` are never applied by CI. A change that needs a role from `bootstrap/` must have that role applied by a human BEFORE the merge, or the apply on `main` fails (idp-infra #45).

Required repository **variables** (not secrets; no keys exist): `GCP_WIF_PROVIDER`, `GCP_PLAN_SA`, `GCP_APPLY_SA`, `BILLING_ACCOUNT_ID`. Values come from `terraform output` in `bootstrap/`.

## Daily use (human)

```bash
time make up          # build the platform (about 20 to 50 minutes), then ./scripts/verify.sh
./scripts/vault-proof.sh      # Vault isolation proofs
./scripts/resource-proof.sh   # buckets and grants against the real broker and Google APIs
time make down        # tear down; also removes stale Tailscale devices and empty tenant buckets
```

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
