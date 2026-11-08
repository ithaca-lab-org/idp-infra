# Tenant resources: broker identity

The in-cluster resource broker (`idp-system/idp-broker`, ADR 0010) creates tenant buckets and sets bucket IAM. This page covers only its Google identity. Terraform: the custom role in `bootstrap/`, the rest in `modules/tenant-resources` (applied by CI in `envs/persistent`).

## What exists

| Resource | Where | Applied by |
|---|---|---|
| Custom role `projects/<project>/roles/idpBrokerBuckets` ("IDP resource broker: tenant buckets", stage GA) | `bootstrap/` | a human, once |
| Service account `idp-broker@` | `modules/tenant-resources` | CI |
| `roles/iam.workloadIdentityUser` on it for `serviceAccount:<project>.svc.id.goog[idp-system/idp-broker]` | `modules/tenant-resources` | CI |
| Project binding: `idp-broker@` gets the custom role, with condition `idp-buckets-and-menu-roles` | `modules/tenant-resources` | CI |

The registry needs no new repository: the image is named `idp-broker` inside the existing repo `idp`.

## Permissions of the custom role

| Permission | Why |
|---|---|
| `storage.buckets.create` | create `idp-<namespace>-<name>` on a BucketClaim |
| `storage.buckets.get` | read the bucket back (labels, ownership check, readiness) |
| `storage.buckets.update` | set labels, versioning off, uniform access, public access prevention |
| `storage.buckets.delete` | delete an empty bucket when the claim goes away |
| `storage.buckets.getIamPolicy` | read the policy before changing it (etag) |
| `storage.buckets.setIamPolicy` | add and remove the per-workload menu binding |

No `storage.objects.*`: the broker cannot read, write or list objects. No project-level storage role.

## The condition

```
resource.name.startsWith("projects/_/buckets/idp-") &&
api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/storage.objectViewer','roles/storage.objectUser'])
```

Built from `bucket_prefix` and `menu_roles`. It blocks: any bucket not named `idp-*` (Terraform state, Vault, others) for every permission above, including create; and any IAM change on a bucket that adds or removes a role other than `objectViewer` / `objectUser` (so no `storage.admin`, no `legacyBucketOwner`). The spike (`docs/tenant-resources-spike.md`) is the evidence for how each half behaves on bucket IAM; if the role limit was not enforced there, the menu is enforced only by broker code and the admission policy. The broker still has no project IAM power: its role carries no `resourcemanager.*` or `iam.*` permission.

## Apply order

1. A human reviews and applies `bootstrap`: `terraform -chdir=bootstrap plan`, expect **1 to add** (the custom role), nothing else; then `terraform -chdir=bootstrap apply`.
2. Merge the persistent change; CI applies: **1 service account, 2 IAM resources** (the Workload Identity member and the conditioned project binding).

**Merge gate:** `gcloud iam roles describe idpBrokerBuckets --project <project>` must succeed before merging the persistent change. Merge before step 1 and the PR plan still looks fine (`google_project_iam_member` does not check the role at plan time), but the apply on main fails: the service account and Workload Identity binding are created, the project binding fails, and every later persistent apply stays red until bootstrap is applied. The CI apply identity cannot create roles (`roles/iam.roleAdmin` is deliberately not granted), which is why the role is in `bootstrap`.

A conditional binding takes about 90 s to propagate (sometimes longer); the broker retries on 403 right after a rebuild or first apply.

## Verify

```bash
P=project-324502ff-9928-4b17-a89
gcloud iam roles describe idpBrokerBuckets --project="$P"      # six permissions, stage GA
gcloud projects get-iam-policy "$P" \
  --flatten='bindings[].members' \
  --filter='bindings.members:idp-broker@' \
  --format='table(bindings.role, bindings.condition.title, bindings.condition.expression)'
gcloud iam service-accounts get-iam-policy "idp-broker@$P.iam.gserviceaccount.com"
```

Expect exactly one project row (the custom role, condition `idp-buckets-and-menu-roles`) and the `workloadIdentityUser` member for `idp-system/idp-broker`.

## Rollback

- Revert the persistent change (CI destroys the service account and both bindings), or remove only `module "tenant_resources"`.
- The custom role stays until a human removes it from `bootstrap` (`terraform -chdir=bootstrap apply` after reviewing the plan: 1 to destroy). The role has `prevent_destroy`; remove that first. A deleted role is soft-deleted for 7 days (can be undeleted), then about 30 more days pass before the ID can be reused, so prefer leaving it.
- Buckets the broker already created are not touched; see the cleanup script in ADR 0010.

## Broker implementation rules

- Set public access prevention (`enforced`) and uniform bucket-level access in the create request itself, never in a follow-up update.
- Never call bucket list (the role has no `storage.buckets.list`; it would fail and invites broad scans). Address buckets by computed name.
- Treat HTTP 409 on bucket delete as "not empty": set `DeleteBlocked`, do not retry or force.

## Guardrails a human must set before RESOURCES_ENABLED

The condition limits **roles**, not **members** and not **bucket settings**. A compromised broker could (a) grant `objectViewer`/`objectUser` on any `idp-*` bucket to an outside identity (`user:...`, `allUsers`); (b) with `storage.buckets.update`, set public access prevention back to inherited or turn off uniform access (ACLs may then bypass the role limit; unverified) and make a bucket public; (c) lock a retention policy, making a bucket undeletable; (d) create many costly buckets. Org policies set by a human close (a) and (b). Placeholders below; nothing here has been run.

```bash
P=<project-id>
gcloud services enable orgpolicy.googleapis.com --project="$P"   # not enabled today
cat > /tmp/pap.yaml <<'YAML'
name: projects/<project-id>/policies/storage.publicAccessPrevention
spec:
  rules:
  - enforce: true
YAML
cat > /tmp/ubla.yaml <<'YAML'
name: projects/<project-id>/policies/storage.uniformBucketLevelAccess
spec:
  rules:
  - enforce: true
YAML
gcloud org-policies set-policy /tmp/pap.yaml
gcloud org-policies set-policy /tmp/ubla.yaml
```

The same commands are in [`scripts/set-tenant-org-policies.sh`](../scripts/set-tenant-org-policies.sh). Run `./scripts/set-tenant-org-policies.sh [project-id]`. It asks for the project ID (or takes it as the first argument or `PROJECT_ID`), shows it and asks you to type `yes`, then runs each `gcloud` command in turn, prints a `[ OK ]` line after each one that succeeded, waits 2 seconds before the next, and stops at the first failure. It only covers the two enforced constraints; the member allow-list below needs a decision first and is not scripted. You need `roles/orgpolicy.policyAdmin` (see below). If the first `set-policy` fails right after the API was enabled, wait a minute and run it again: the commands are idempotent. Nothing here has been run.

**Status (2026-11-08):** `storage.publicAccessPrevention` and `storage.uniformBucketLevelAccess` are ENFORCED on the project (set with `scripts/set-tenant-org-policies.sh`, confirmed with `gcloud org-policies describe <constraint> --project=<project> --effective`). That closes the public-bucket path and the ACL bypass of the role limit. The member allow-list is NOT set (see below).

Permissions: project Owner is not enough to set org policies (`orgpolicy.policies.create` is denied). An organisation admin must grant `roles/orgpolicy.policyAdmin` first. It was granted on the ORGANISATION to the owner account, so remove it there when done: `gcloud organizations remove-iam-policy-binding <org-id> --member=user:<account> --role=roles/orgpolicy.policyAdmin` (the `projects` form says "binding not found" when it was granted on the organisation).

Member allow-list (not set, decision pending): both constraints exist on the project and are unset (`iam.allowedPolicyMemberDomains` allowAll, `iam.managed.allowedPolicyMembers` enforce false). The managed constraint is configured like this (from Google's documentation; it shows no example for Workload Identity pool principals, so which `allowedPrincipalSets` value matches `principal://...svc.id.goog` members is unproven):

```yaml
name: projects/<project-number>/policies/iam.managed.allowedPolicyMembers
spec:
  rules:
  - enforce: true
    parameters:
      allowedMemberSubjects: [user:<owner-account>]
      allowedPrincipalSets: [<workload identity pool and the project's service accounts: to be determined>]
```

Why it is not enforced now: Google warns that restricting members can stop Google-managed service agents and our own service accounts (the Terraform apply and plan accounts, the node, Vault and portal service accounts, the pool itself) from being granted roles, so an unrelated IAM change could start failing. Do it in two steps if wanted: first a policy with `dryRunSpec` instead of `spec` (violations are logged, nothing is blocked), grant a test `principal://` member on a test bucket and look for a logged violation, list every principal the platform legitimately uses until the dry run is quiet, and only then enforce. The residual risk without it: a compromised broker could grant `objectViewer` or `objectUser` on an `idp-*` bucket to an outside account (it cannot make a bucket public). It stays an accepted risk for a single-user lab until the dry run is done.

Verify afterwards: create a test bucket `idp-guardrail-test`, bind `roles/storage.objectUser` for a test `principal://iam.googleapis.com/projects/<project-number>/locations/global/workloadIdentityPools/<project-id>.svc.id.goog/subject/ns/<ns>/sa/<ksa>`, confirm a pod of that ServiceAccount can read and write, that granting to `allUsers` or an outside `user:` is rejected, and that disabling public access prevention is rejected. Delete the test bucket and binding.

### Accepted risk until then

Until the org policies are set (and while `orgpolicy.googleapis.com` is not enabled), the broker can do (a) to (d) above to `idp-*` buckets. Also accepted: a retention lock can make a bucket undeletable until its retention expires, and bucket count is limited only by the portal caps and the budget alert. Keep `RESOURCES_ENABLED` off until the guardrails are in place, or accept this for a single-user lab explicitly.
