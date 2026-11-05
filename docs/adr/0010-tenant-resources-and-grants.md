# 0010. Tenant cloud resources and workload grants

- Status: proposed (nothing built; two points marked "verify" need a spike first)
- Date: 2026-11-05

## Context

A workload (ADR 0009) has its own ServiceAccount and so a Kubernetes identity. Tenants also need Google Cloud resources (a bucket first, a Pub/Sub topic later) and a way for their workload to use them without keys. GKE Workload Identity Federation can name a ServiceAccount directly as an IAM principal, so no Google service account (GSA) has to be created per workload:

`principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<namespace>/sa/<workload>`

(`principalSet://.../namespace/<namespace>` names a whole namespace.) The pod needs no annotation and no key file: client libraries get a short-lived token through Application Default Credentials.

The hard part is who holds the IAM power. Setting IAM policy and creating resources from the in-cluster operator would let a compromised operator, or a tenant who tricked it, widen access across the project. Platform service accounts so far (`vault-server@`, `portal-api@`, `notifier@`, the cert-manager DNS-01 account) are created by Terraform with one narrow role each (the pattern of `modules/order-events` and `modules/vault-unseal`, both in `envs/persistent`).

## Decision

Direct principal bindings (no per-workload GSA), requested through a fixed menu, written by a small separate **resource broker** that is not the general operator.

- **Two namespaced CRs, written only by the portal (like `ManagedSecret`):**
  - `BucketClaim` (name = bucket suffix; empty or near-empty spec in v1). The broker creates the bucket `idp-<namespace>-<name>`, in the platform region, with uniform bucket-level access, public access prevention enforced, versioning off, a labelled owner (`idp-namespace=<namespace>`), and no force delete (see Lifecycle).
  - `ResourceGrant` with `spec.workload`, `spec.resource` (a claim in the same namespace) and `spec.access` in `reader | writer`. The menu is fixed in code and in the admission policy: `reader` = `roles/storage.objectViewer`, `writer` = `roles/storage.objectUser`. No admin roles, no custom role names, no bucket-level or project-level roles.
- **What the broker checks before it binds:** the `WorkloadIdentity` named in the grant exists in the same namespace; the claim exists in the same namespace and carries the ownership label; the access level is in the menu. It then adds one binding on that bucket only, for `principal://.../ns/<namespace>/sa/<workload>`, and removes it when the grant is deleted (and when the `WorkloadIdentity` is deleted, through a finalizer, like the Vault purge in ADR 0009). It never edits project-level IAM.
- **The broker is a separate Deployment** (`idp-system/idp-broker`, its own ServiceAccount and image entry point) with its own Google service account `idp-broker@`, bound through classic KSA to GSA Workload Identity. It can: create and delete buckets whose name starts with `idp-`, and set IAM policy on such buckets. It cannot read objects, touch other buckets (Terraform state, Vault), or change project IAM. The prefix limit is an IAM condition on the resource name (defence in depth: the broker also computes names itself, and an admission policy pins the objects it may write).
- **Portal:** a Resources page (order a bucket, list, detail) and a grant form on the workload page, behind a flag like `SECRETS_ENABLED` (`RESOURCES_ENABLED`, default off). Authorization is the same admin-of-namespace check as Secrets and Workloads. Per-namespace caps (buckets, grants) and rate limits as for workloads.
- **Granularity:** per workload by default; `principalSet` per namespace is not offered in v1.

## Consequences

- Tenants never edit IAM and never get a key. A grant is one reviewed shape: a menu role on one owned resource for one workload.
- A compromised broker can widen or revoke access to tenant buckets (or delete empty ones) but cannot reach platform buckets, secrets, KMS or project IAM, if the IAM conditions hold (see verify points).
- Cloud Audit Logs show which principal (`ns/<ns>/sa/<name>`) called the API.
- Isolation inside one namespace is as in ADR 0009: a tenant admin can create more ServiceAccounts, but a grant names one ServiceAccount, so another workload does not inherit it. Anyone able to run a pod as that ServiceAccount does use it.
- Some Google APIs do not accept direct principal identities. Cloud Storage and Pub/Sub are fine to start; each new resource type must be checked against the list of supported APIs, and a type that is not supported needs a GSA (option: a pre-created GSA bound by Terraform).
- IAM changes take a few minutes to propagate; the grant condition `Ready` reflects the API call, not propagation.

## Lifecycle on a cluster that is rebuilt often

`make down` destroys the cluster, the TeamNamespaces and the claims, but not buckets or IAM bindings, which live in the project. Without a plan these would leak. Decision: a script `scripts/tenant-resources-cleanup.sh` (dry run by default, like `scripts/tailscale-cleanup.sh`) lists buckets labelled `idp-managed=true` and deletes the empty ones and the bindings to principals of namespaces that no longer exist; `make down` runs it after destroy. A bucket with objects is never deleted automatically: the script reports it and a human decides. The bucket delete from the broker (claim deleted) also refuses non-empty buckets and sets a condition `DeleteBlocked` on the claim.

## Verify before building (spike)

1. **IAM conditions:** that `idp-broker@` can be limited to buckets named `idp-*` for create and for setIamPolicy through a condition on `resource.name`, and whether a condition that limits which roles may be granted is available for bucket IAM (project-level `modifiedGrantsByRole` is documented, bucket-level may not be). If the role limit is not enforceable, the menu is enforced only in broker code plus the admission policy, and the Opus review must say so.
2. That a pod using only the principal binding (no annotation) reads and writes through Application Default Credentials with the Go and the `gcloud storage` clients we ship, and that a pod of another ServiceAccount or namespace is denied.
3. Bucket name collisions: bucket names are global; `idp-<ns>-<name>` can already exist elsewhere. Decide between failing with a clear message and adding a short project-derived suffix.

## Implementation plan

Rough sizes are for one person with agents doing the first drafts; every IAM or admission piece gets an Opus review before merge. Nothing is applied by an agent (`terraform apply`, `make up`, `kubectl apply` stay with the user).

| # | Work | Repo | Size |
|---|---|---|---|
| 0 | Spike: the three verify points, by hand on a cluster (create a bucket, bind a ServiceAccount principal, read from a pod; try the IAM conditions with a throwaway GSA) | none (notes only) | S |
| 1 | Terraform module `tenant-resources` in `envs/persistent` (CI applied): `idp-broker@`, conditioned grants for create/IAM on `idp-*` buckets, the `workloadIdentityUser` binding for `idp-system/idp-broker`, Storage API enabled, labels; Opus review | idp-infra | M |
| 2 | CRDs `BucketClaim`, `ResourceGrant`; broker controllers behind a Go interface for the Storage/IAM calls (fake in tests); finalizers and the purge of bindings; admission policy `idp-broker-scope` (names, menu, ownership label, no foreign writes) with envtests | idp-portal | L |
| 3 | Portal API and UI: Resources page, grant form on the workload page, flag `RESOURCES_ENABLED`, caps, rate limit, tests; portal-scope policy for the two kinds | idp-portal | M |
| 4 | Deploy: broker Deployment, ServiceAccount with the GSA annotation, RBAC, NetworkPolicy and egress to Google APIs, flag, image pins | idp-gitops | S |
| 5 | Proof: `verify.sh` smoke (claim and grant produce the bucket and binding), `scripts/resource-proof.sh` (a Job as workload A reads and writes its bucket; denied on another namespace's bucket, on another workload's grant, after the grant is removed) | idp-infra | M |
| 6 | `scripts/tenant-resources-cleanup.sh` and its `make down` hook, ADR status update, docs | idp-infra | S |

Order: 0, then 1 and 2 in parallel, then 3 and 4, then 5 and 6. Cost: buckets are cheap but not free; the per-namespace cap (for example 3 buckets and 10 grants) and the existing budget alert cover it.

## Open items

- The resource menu after buckets (Pub/Sub topic and subscription is the natural second; Cloud SQL has its own deferred design, see IDP_NOTES.md section 11).
- Whether a namespace-wide `principalSet` grant is ever offered.
- Quotas and an approval gate (the "approval/CHG gate" idea in the notes) for resource orders.
