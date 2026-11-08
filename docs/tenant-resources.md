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

Member allow-list: use `constraints/iam.allowedPolicyMemberDomains` (customer ID `<directory-customer-id>`) or the managed constraint `iam.managed.allowedPolicyMembers`, which can allow the project's Workload Identity pool principals (`<project-id>.svc.id.goog`) plus your own identity. **Verify which works with `principal://...svc.id.goog` members before enforcing:** the domain constraint may reject principal identities. Start with a dry-run policy where available, and keep a break-glass path (policy admin role for you, not CI). The caller needs `roles/orgpolicy.policyAdmin` on the project or its organization (`<org-id>`); CI has no such role.

Verify afterwards: create a test bucket `idp-guardrail-test`, bind `roles/storage.objectUser` for a test `principal://iam.googleapis.com/projects/<project-number>/locations/global/workloadIdentityPools/<project-id>.svc.id.goog/subject/ns/<ns>/sa/<ksa>`, confirm a pod of that ServiceAccount can read and write, that granting to `allUsers` or an outside `user:` is rejected, and that disabling public access prevention is rejected. Delete the test bucket and binding.

### Accepted risk until then

Until the org policies are set (and while `orgpolicy.googleapis.com` is not enabled), the broker can do (a) to (d) above to `idp-*` buckets. Also accepted: a retention lock can make a bucket undeletable until its retention expires, and bucket count is limited only by the portal caps and the budget alert. Keep `RESOURCES_ENABLED` off until the guardrails are in place, or accept this for a single-user lab explicitly.

## Proof

`scripts/resource-proof.sh` proves ADR 0010 against the real broker and the real Google APIs. Run it by hand from a laptop (it is not part of `make up` or CI) with `gcloud` (project set; allowed to read the project, buckets and org policies, and to create and delete buckets), `kubectl` (cluster admin on the idp cluster) and `jq`.

```bash
PROOF_DRY_RUN=1 ./scripts/resource-proof.sh      # prints the plan, creates nothing
./scripts/resource-proof.sh                      # asks you to type yes (PROOF_YES=1 skips)
PROOF_BROKER_LIMITS=off ./scripts/resource-proof.sh   # skip step 7 (no impersonation)
```

Needs: `BROKER_ENABLED=true` on `idp-system/idp-broker` (it ships disabled; flip it in `idp-gitops` `workloads/idp-operator/idp-broker.yaml`), the Terraform in this page applied (role `idpBrokerBuckets`, the conditional binding), and the guardrails above (`storage.publicAccessPrevention` and `storage.uniformBucketLevelAccess` effectively enforced). The preflight fails with a pointer here if one is missing, and refuses to run when `rproof-a`, `rproof-b` or a bucket `idp-rproof-*` is left over.

What it creates: TeamNamespaces `rproof-a` and `rproof-b`, WorkloadIdentities `wl-a`, `wl-other` (a) and `wl-b` (b), BucketClaims `data` and `empty`, ResourceGrants `wl-a-data` and `wl-other-data`, short-lived `curlimages/curl` pods, buckets `idp-rproof-a-data-<hash>` and `idp-rproof-a-empty-<hash>`, and, with limits on and only if impersonation fails, `roles/iam.serviceAccountTokenCreator` for you on `idp-broker@` (removed at the end). Everything is removed by an EXIT trap; buckets only when name, owner label and claim UID all belong to this run.

Steps (`PASS`/`FAIL` each): 1 preflight; 2 namespaces and workload identities; 3 bucket name, labels, public access prevention, uniform access, location; 4 the grant adds exactly one binding; 5 `wl-a` writes and reads (200), `wl-other` and `wl-b` get 403; 6 reader reads (200) and cannot write (403), revoke gives 403 and removes the binding; 7 broker limits as `idp-broker@`: objectViewer allowed, `storage.admin` denied, removal allowed, `allUsers` denied, outside member observed only (it uses your own account, a project member, so it cannot detect a domain allow-list; expected allowed: the accepted risk), non-`idp-` bucket denied, state bucket denied; 8 deleting a claim with an object orphans the bucket (`idp-orphaned=true`, no principal binding left), an empty claim's bucket is deleted and a re-created claim is Ready. Expected summary: every line `PASS`, `OBS` lines for step 7, final `RESULT: all proofs passed`; exit code non-zero on any FAIL. Unproven until the first run: 7b, 7c (removal under the custom role), 8b to 8d, and the `gcloud` JSON field names it reads.

Duration: about 15 to 30 minutes (IAM propagation can take minutes, conditional bindings about 90 s, namespace deletion up to `PROOF_DELETE_TIMEOUT`). Timeouts: `PROOF_READY_TIMEOUT` (180), `PROOF_PROP_TIMEOUT` (300), `PROOF_COND_TIMEOUT` (300), `PROOF_DENY_TIMEOUT` (60), `PROOF_DELETE_TIMEOUT` (300).

If a run is killed, clean by hand (the next run refuses until this is done):

```bash
kubectl delete teamnamespace rproof-a rproof-b            # the broker then releases the claims
gcloud storage buckets list --filter='name~^idp-rproof-' --format='value(name)'
gcloud storage rm --recursive gs://<bucket>               # only buckets listed above
gcloud iam service-accounts get-iam-policy idp-broker@<project>.iam.gserviceaccount.com   # a leftover tokenCreator for you
gcloud iam service-accounts remove-iam-policy-binding idp-broker@<project>.iam.gserviceaccount.com \
  --member=user:<you> --role=roles/iam.serviceAccountTokenCreator
```

## Cleanup after make down

`make down` destroys the cluster but not buckets or bucket IAM. `scripts/tenant-resources-cleanup.sh` handles that; `make down` runs it with `--delete --assume-cluster-gone` after the destroy, and `make tenant-resources-cleanup` (`DELETE=1` to act) runs it by hand.

- Dry run by default; `--delete` acts. It lists buckets labelled `idp-managed=true` (name `idp-*`, this project's number, all in the same listing row).
- It acts only when it knows which TeamNamespaces exist: `kubectl get teamnamespaces` answered, or `--assume-cluster-gone` was given. **An unreachable cluster is not a gone cluster:** without the flag an unreachable cluster means do nothing. The flag trusts you, so never use it while a cluster exists (the script refuses if `gcloud container clusters describe` still finds the cluster).
- Namespace gone and bucket empty: deleted. Not empty: reported as `ORPHAN` with the object count, never deleted (you decide: `gcloud storage rm --recursive gs://<bucket>`).
- Bindings for `principal://.../ns/<ns>/sa/<x>` of this project's pool for a namespace that no longer exists are removed in one read-modify-write per bucket (kept orphans included); all other bindings stay as they were.
- Skips buckets with `idp-releasing=true` updated in the last 10 minutes; refuses more than 50 actions per run. A dry run exits 0.
- Safety checks: without `--assume-cluster-gone` it needs the idp cluster context (`gke_<project>_<zone>_<cluster>`) and refuses to act when the cluster shows 0 TeamNamespaces while idp-managed buckets exist (a fresh or wrong cluster). With the flag it proceeds only when `gcloud container clusters describe` answers NOT_FOUND; any other error (auth, network, wrong zone) stops it with nothing changed. Buckets younger than 10 minutes are skipped as too new.
