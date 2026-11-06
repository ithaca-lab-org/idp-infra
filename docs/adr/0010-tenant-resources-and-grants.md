# 0010. Tenant cloud resources and workload grants

- Status: proposed (nothing built; the spike of 2026-11-05 answered the open points, see "Spike findings")
- Date: 2026-11-05

## Context

A workload (ADR 0009) has its own ServiceAccount and so a Kubernetes identity. Tenants also need Google Cloud resources (a bucket first, a Pub/Sub topic later) and a way for their workload to use them without keys. GKE Workload Identity Federation can name a ServiceAccount directly as an IAM principal, so no Google service account (GSA) has to be created per workload:

`principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<namespace>/sa/<workload>`

(`principalSet://.../namespace/<namespace>` names a whole namespace.) The pod needs no annotation and no key file: client libraries get a short-lived token through Application Default Credentials.

The hard part is who holds the IAM power. Setting IAM policy and creating resources from the in-cluster operator would let a compromised operator, or a tenant who tricked it, widen access across the project. Platform service accounts so far (`vault-server@`, `portal-api@`, `notifier@`, the cert-manager DNS-01 account) are created by Terraform with one narrow role each (the pattern of `modules/order-events` and `modules/vault-unseal`, both in `envs/persistent`).

## Decision

Direct principal bindings (no per-workload GSA), requested through a fixed menu, written by a small separate **resource broker** that is not the general operator.

- **Two namespaced CRs, written only by the portal (like `ManagedSecret`):**
  - `BucketClaim` (name = bucket suffix; empty or near-empty spec in v1). The broker creates the bucket `idp-<namespace>-<claim>-<8 hex>` (the suffix is the start of `sha256(projectNumber/namespace/claim)`: it removes the ambiguity between `a-b`/`c` and `a`/`b-c` and makes names unguessable for squatting; namespace at most 31 and claim at most 18 characters so the name fits 63; names containing `google` or starting with `goog` are rejected), in the platform region, with uniform bucket-level access, public access prevention enforced, versioning off, a labelled owner (`idp-namespace=<namespace>`), and no force delete (see Lifecycle).
  - `ResourceGrant` with `spec.workload`, `spec.resource` (a claim in the same namespace) and `spec.access` in `reader | writer`. The menu is fixed in code and in the admission policy: `reader` = `roles/storage.objectViewer`, `writer` = `roles/storage.objectUser`. No admin roles, no custom role names, no bucket-level or project-level roles.
- **Ownership rules (review of 2026-11-05):** bucket names are global, so the broker acts on a bucket only if it belongs to THIS project (project number checked on every read, adopt, bind, release and delete) and carries `idp-managed=true`, `idp-namespace`, `idp-claim` and the claim UID (`idp-claim-uid`); adoption is only for crash-retry of the same claim. A bucket owned by someone else gives `NameTaken` and is never touched.
- **What the broker checks before it binds:** the `WorkloadIdentity` named in the grant exists in the same namespace; the claim exists in the same namespace and carries the ownership label; the access level is in the menu. It then adds one binding on that bucket only, for `principal://.../ns/<namespace>/sa/<workload>`, and removes it when the grant is deleted (and when the `WorkloadIdentity` is deleted, through a finalizer, like the Vault purge in ADR 0009). It never edits project-level IAM.
- **The broker is a separate Deployment** (`idp-system/idp-broker`, its own ServiceAccount and image entry point) with its own Google service account `idp-broker@`, bound through classic KSA to GSA Workload Identity. It can: create and delete buckets whose name starts with `idp-`, and set IAM policy on such buckets. It cannot read objects, touch other buckets (Terraform state, Vault), or change project IAM. The prefix limit is an IAM condition on the resource name (defence in depth: the broker also computes names itself, and an admission policy pins the objects it may write).
- **Portal:** a Resources page (order a bucket, list, detail) and a grant form on the workload page, behind a flag like `SECRETS_ENABLED` (`RESOURCES_ENABLED`, default off). Authorization is the same admin-of-namespace check as Secrets and Workloads. Per-namespace caps (buckets, grants) and rate limits as for workloads.
- **Granularity:** per workload by default; `principalSet` per namespace is not offered in v1.

## Consequences

- Tenants never edit IAM and never get a key. A grant is one reviewed shape: a menu role on one owned resource for one workload.
- **What a compromised broker can and cannot do (IAM review, 2026-11-06).** It cannot reach platform buckets, secrets, KMS or project IAM, and it can only grant the two menu roles. But the IAM condition limits ROLES, not MEMBERS and not bucket settings: it could grant a menu role on an `idp-*` bucket to an outside account, switch public access prevention or uniform access off with `storage.buckets.update` and make a bucket public, lock a retention policy (undeletable bucket) or create costly buckets. No condition attribute restricts members, so the closing control is project-level organisation policy set by a human BEFORE the feature is enabled: `storage.publicAccessPrevention` and `storage.uniformBucketLevelAccess` enforced, plus a member allow-list (the exact constraint that accepts `principal://...svc.id.goog` members must be tested first). The runbook is `docs/tenant-resources.md` ("Guardrails a human must set before RESOURCES_ENABLED"); until then this is an accepted lab risk and the portal flag stays off.
- Cloud Audit Logs show which principal (`ns/<ns>/sa/<name>`) called the API.
- Isolation inside one namespace is as in ADR 0009: a tenant admin can create more ServiceAccounts, but a grant names one ServiceAccount, so another workload does not inherit it. Anyone able to run a pod as that ServiceAccount does use it.
- Some Google APIs do not accept direct principal identities. Cloud Storage and Pub/Sub are fine to start; each new resource type must be checked against the list of supported APIs, and a type that is not supported needs a GSA (option: a pre-created GSA bound by Terraform).
- IAM changes take a few minutes to propagate; the grant condition `Ready` reflects the API call, not propagation.

## Lifecycle on a cluster that is rebuilt often

`make down` destroys the cluster, the TeamNamespaces and the claims, but not buckets or IAM bindings, which live in the project. Without a plan these would leak. Decision: a script `scripts/tenant-resources-cleanup.sh` (dry run by default, like `scripts/tailscale-cleanup.sh`) lists buckets labelled `idp-managed=true` and deletes the empty ones and the bindings to principals of namespaces that no longer exist; `make down` runs it after destroy. A bucket with objects is never deleted automatically: the script reports it and a human decides. Releasing a claim (deleted, or its namespace deleted) runs in this order so that a grant cannot re-add access meanwhile: label the bucket `idp-releasing=true`, strip every binding the broker manages, try to delete it (the Storage API refuses a non-empty bucket with 409, so the broker needs no `storage.objects.*` permission), and on 409 label it `idp-orphaned=true` and strip the bindings again. The finalizer is then removed in every case, so a stuck release never blocks namespace deletion or `make down`; an orphaned bucket keeps its data unreachable by tenants until a human decides. A re-created claim of the same name gets `NameTaken` while the orphan exists. The broker's Google permissions are exactly `storage.buckets.create|get|update|delete|getIamPolicy|setIamPolicy`, on `idp-*` buckets, with the menu-role limit.

## Spike findings (2026-11-05, scripts/spike-tenant-resources.sh, throwaway resources)

1. **A bare principal binding works.** With no annotation and no key, a pod running as `spike-a` got HTTP 200 on write and read of its bucket, 403 on another bucket and 403 as `spike-b` on `spike-a`'s bucket (binding `principal://.../ns/<ns>/sa/spike-a` as `roles/storage.objectUser` on one bucket). Propagation was under a second here. Only curl with the metadata token was tried: the Go and `gcloud` clients are still to be checked in the proof (step 5 of the plan).
2. **IAM conditions limit the broker, including the role menu.** A project-level `roles/storage.admin` for a service account with the condition `resource.name.startsWith("projects/_/buckets/idp-spike-")` allowed creating `idp-spike-*` buckets and setting IAM on them, denied creating a bucket without the prefix, and denied reading the Terraform state bucket's IAM. Adding `api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([...menu roles...])` to the condition still allowed granting a menu role (`objectUser`) and denied granting `roles/storage.admin` on a bucket, so the menu is enforceable in IAM and the broker code and admission policy are a second line, not the only one. Conditional bindings took about 90 seconds to propagate, so the Terraform apply must be done well before the broker first runs, and tests must wait or retry.
3. **Bucket-name collisions:** the one name tried was free, so the error text was not seen. Bucket names are global; the broker must treat a conflict from the Storage API as a normal failure (condition `Ready=False`, reason `NameTaken`) and the portal should show it. A short project-derived suffix stays an option if collisions turn out to be common.

Not covered by the spike (to check in the proof): that the broker can also remove a binding and delete an empty bucket under the same conditions (the role limit should not block removals of menu roles), the Go client with a bare principal, and the object-level views (a `reader` cannot write).

## Implementation plan

Rough sizes are for one person with agents doing the first drafts; every IAM or admission piece gets an Opus review before merge. Nothing is applied by an agent (`terraform apply`, `make up`, `kubectl apply` stay with the user).

| # | Work | Repo | Size |
|---|---|---|---|
| 0 | Spike: DONE 2026-11-05 (idp-infra #44, findings above) | idp-infra | done |
| 1 | Terraform module `tenant-resources` in `envs/persistent` (CI applied; the custom role lives in `bootstrap/`, human-applied first): `idp-broker@`, conditioned grants for create/IAM on `idp-*` buckets, the `workloadIdentityUser` binding for `idp-system/idp-broker`, Storage API enabled, labels; Opus review | idp-infra | M |
| 2 | CRDs `BucketClaim`, `ResourceGrant`; broker controllers behind a Go interface for the Storage/IAM calls (fake in tests); finalizers and the purge of bindings; admission policy `idp-broker-scope` (names, menu, ownership label, no foreign writes) with envtests | idp-portal | L |
| 3 | Portal API and UI: Resources page, grant form on the workload page, flag `RESOURCES_ENABLED`, caps, rate limit, tests; portal-scope policy for the two kinds | idp-portal | M |
| 4 | Deploy: broker Deployment, ServiceAccount with the GSA annotation, RBAC, NetworkPolicy and egress to Google APIs, flag, image pins | idp-gitops | S |
| 5 | Proof: `verify.sh` smoke (claim and grant produce the bucket and binding), `scripts/resource-proof.sh` (a Job as workload A reads and writes its bucket; denied on another namespace's bucket, on another workload's grant, after the grant is removed) | idp-infra | M |
| 6 | `scripts/tenant-resources-cleanup.sh` and its `make down` hook, ADR status update, docs | idp-infra | S |

Order: 1 and 2 in parallel, then 3 and 4, then 5 and 6. Cost: buckets are cheap but not free; the per-namespace cap (for example 3 buckets and 10 grants) and the existing budget alert cover it.

## Open items

- The resource menu after buckets (Pub/Sub topic and subscription is the natural second; Cloud SQL has its own deferred design, see IDP_NOTES.md section 11).
- Whether a namespace-wide `principalSet` grant is ever offered.
- Quotas and an approval gate (the "approval/CHG gate" idea in the notes) for resource orders.
