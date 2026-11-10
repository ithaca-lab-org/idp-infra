# 0011. Tenant delivery with Spinnaker (Order #04 `DeliveryPipeline`)

- Status: proposed (design only; nothing built, nothing verified on a cluster)
- Date: 2026-11-10

## Context

A tenant can order a namespace, a workload identity (ADR 0009), secrets and buckets (ADR 0010), but has no way to get a container running. No workload sits behind a route yet. `IDP_NOTES.md` section 3 (steps 04 and 05) designs the delivery path: a `DeliveryPipeline` order creates a Spinnaker application and pipeline, and a reusable GitHub workflow triggers it with an image digest.

Argo CD already deploys the platform (ADR 0003) and stays the platform tool. Spinnaker is kept for tenant delivery on purpose (user decision, 2026-11-10): it shows both tools in one repo set, and the notes call it the heaviest component (about 6 to 8 GiB RAM, about ten services).

## Decision (proposed)

- **Spinnaker is installed by Argo CD** from the `spinnaker-kustomize` path of the Spinnaker monorepo (a pinned 2026.x release as the base, our overlay on top). Not the Armory Spinnaker Operator (reported deprecated) and not Halyard (removed in 2026.3.0); both findings come from a web-only research pass on 2026-11-10 and are not yet verified. Minimal set: Deck, Gate, Orca, Clouddriver, Front50, Rosco, Fiat (when authorization is on), Echo only if triggers are needed (see point 4), plus an in-cluster SQL database; Igor and Kayenta off unless needed. UI over Tailscale like the other admin UIs, own namespace behind the mesh. It joins the `make up` rebuild, so its start time and memory are part of the cost review (see Open points).
- **`DeliveryPipeline` is a namespaced CR written only by the portal**, like `BucketClaim`. Spec: `workload` (an existing `WorkloadIdentity` in the same namespace) and the repository coordinates. Status moves `PENDING -> BUILDING -> READY` as in the notes.
- **A separate controller reconciles it, not `idp-operator`.** Same reasoning as the broker in ADR 0010: the component that holds Spinnaker credentials gets its own Deployment, ServiceAccount and admission-policy pin, so a compromise of the general operator does not reach the delivery system. It creates the application and renders the pipeline from a template in a new `idp-golden-paths` repo, through the Gate API, and confirms it exists before `READY`. Tenants never edit pipeline JSON: the namespace and workload are baked in by the controller.
- **Ownership rule (decision, matches section 3 step 06):** Spinnaker deploys only `Deployment` and `Service` objects. The platform owns the HTTPRoute, the ServiceAccount, the AuthorizationPolicy, NetworkPolicies, RBAC and Secrets. Spinnaker's Kubernetes account is bound by a per-tenant-namespace Role limited to those two kinds, never a cluster-wide write role, and an admission policy pins what it may write. This is the main security control and needs an Opus review.
- **Tenant isolation inside Spinnaker:** Fiat roles come from the Keycloak group claims; a pipeline for namespace A can only target namespace A (enforced by the controller template and by the Role, not by trust in the pipeline).
- **Pods must match the platform identity:** a deployed pod must use `serviceAccountName: <workload>` and carry the label `idp.ithaca-idp.com/workload=<name>` (otherwise the AuthorizationPolicy, Vault role and IAM principal do not apply). An admission policy should reject tenant pods that name a ServiceAccount without an existing `WorkloadIdentity`.
- **Trigger and artifacts:** the GitHub workflow (Order #05, later) passes the image digest and git SHA. Deploy by digest, never by tag. Manifests come from the app repo as Kustomize (`deploy/base`), baked by Rosco (decided, see Open points).
- **Change management:** creating a pipeline in the tenant's own namespace is a pre-approved standard change (quota-limited, audited in the portal). Production-classified namespaces can later add a manual-judgment stage that waits for an approved iTop CHG; that depends on the approval gate (candidate d) and is out of scope here.

## Out of scope

HTTPRoute weights and version retirement (Order #06), the golden-path workflow, signing and Kyverno image verification (Order #05 and the supply-chain phase), `DatabaseClaim`, canary analysis (Kayenta).

## Open points (each needs a spike or a number before building)

1. **Footprint.** The pool is Spot `e2-standard-4` (4 vCPU, 16 GiB), autoscaling 1 to 4 (`modules/gke`, variable `machine_type`). Spinnaker alone is about 5 to 8 GiB plus its database (an unmeasured estimate; the install docs quote 18 GB RAM and 6 cores for a whole cluster), on top of Istio, Keycloak, Vault, MongoDB and the portal. The next size that fits comfortably is `e2-standard-8` (8 vCPU, 32 GiB); `e2-highmem-4` (4 vCPU, 32 GiB) is the alternative if CPU is not the limit. The spike first measures real requests on the existing pool (the autoscaler may simply add a second node); only if that is not enough is `machine_type` changed. Cost goes in the README.
2. **Storage.** The 2026.3.0 changelog reportedly deprecates Redis execution storage and Front50 blob storage (GCS/S3), with SQL required by 2027.0.0. Plan for an in-cluster MariaDB or MySQL (one database per service) for the spike, and drop the GCS bucket idea unless the spike shows SQL is not workable. A throwaway database is destroyed with the cluster, so there are no stale pipelines. Unverified: whether Redis-only still starts on 2026.3.
3. **Gate authentication for the controller.** x509 is the documented path for non-UI clients (certificate from an internal CA, roles in an extension, optionally a separate API port). No documented API-token or client-credentials mechanism was found; a bearer JWT from Keycloak is unverified. Deck login through Keycloak OIDC with Fiat roles from the `groups` claim is also unverified. The spike proves both.
4. **How the trigger reaches Spinnaker.** A webhook from GitHub-hosted runners needs Gate or Echo reachable from the internet (extra exposure, weak default auth). Alternative: an Echo Pub/Sub trigger on the Artifact Registry topic (Echo documents the GCR message format; Artifact Registry should publish the same `gcr` topic, unverified) with Workload Identity and no inbound exposure; this keeps Echo in the install. Or the workflow calls the portal API, which triggers Spinnaker.
5. **Bake: decided (2026-11-10), use Rosco's Kustomize bake** (as in section 3 step 04). Rosco stays in the install. Reported: the 2026.3.0 changelog adds Kustomize 5 and deprecates Kustomize 3, and older Spinnaker broke on Kustomize 4+; the bake needs a `git/repo` artifact (not a plain GitHub file artifact), and private repos need a token or key on Rosco. To check in the spike: the bundled Kustomize version and a bake of `deploy/base` from a `git/repo` artifact.
6. **Spinnaker Kubernetes account model:** one account per tenant namespace (many accounts, simple least privilege) versus one account with an explicit `namespaces:` list and a Role per namespace. With no list Clouddriver lists all namespaces and needs a cluster-wide role, so always list them. The Role also needs read on `replicasets`, `pods` and `events` besides `deployments` and `services`; cluster-scoped reads (CRD discovery) are unverified. Clouddriver caching cost grows with accounts.
7. **Admission policy for tenant pods** (item above) belongs with the supply-chain work if Kyverno comes first.

## Suggested build order (separate PRs, Opus review on 2 to 4)

1. This ADR, reviewed and settled.
2. Spike: Spinnaker minimal on a throwaway `make up`, measure memory and start time, prove Gate auth and one hand-made pipeline deploying a test Deployment under the restricted Role (human runs the cluster).
3. `idp-gitops`: Spinnaker (`spinnaker-kustomize` base plus overlay), SQL database, RBAC, flags off.
4. `idp-golden-paths` repo: pipeline template and the Kustomize base.
5. `idp-portal`: `DeliveryPipeline` CRD, controller, admission policy, portal page behind a flag.
6. Proof script (like `resource-proof.sh`) and `verify.sh` smoke check.
