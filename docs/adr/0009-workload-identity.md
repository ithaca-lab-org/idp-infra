# 0009. Per-workload identity (WorkloadIdentity)

- Status: accepted for the parts built; open items listed below
- Date: 2026-11-02

## Context

Order #03 gives each workload in a tenant namespace its own identity: a ServiceAccount (and so a SPIFFE ID from Istio ambient), a reserved hostname, a default AuthorizationPolicy and per-workload access to its Vault path `kv/<ns>/<workload>/`. TeamNamespaces (ADR 0007 and the operator) already give tenants a guarded namespace with `vault-reader`; this adds the finer unit.

## Decision

- **API:** a namespaced `WorkloadIdentity` CR with an empty spec; its name is the workload name. The operator creates, all named `<workload>`: ServiceAccount, HTTPRoute, AuthorizationPolicy and (with Vault on) a VSO `VaultAuth`. Status carries `spiffeID`, `hostname` and a `Synced` condition. Details: idp-portal `operator/README.md`.
- **SPIFFE ID:** `spiffe://cluster.local/ns/<ns>/sa/<workload>`. A custom trust domain is deferred: changing it re-issues every workload certificate and touches existing policies. The operator already has a `--trust-domain` flag, so the later switch is a configuration change plus a rollout.
- **AuthorizationPolicy selects pods by label.** Ambient without a waypoint is enforced by ztunnel, which applies only L4 rules, and Istio 1.27 cannot target a ServiceAccount (`targetRefs` takes Gateway, GatewayClass, Service, ServiceEntry). The policy therefore selects pods with `idp.ithaca-idp.com/workload=<workload>`; workload pods must carry that label, otherwise only the namespace NetworkPolicies apply to them.
- **Vault:** one Kubernetes auth role and one templated policy, both `workload-reader`. The policy lets a caller read `kv/data/<ns>/<sa>/*` (and read/list the metadata) with `<ns>` and `<sa>` taken from the verified alias metadata, so no Vault change per workload. The role accepts any ServiceAccount name but is bound by a namespace label selector (`app.kubernetes.io/managed-by=idp-operator`), because path denies cannot exclude platform namespaces: a deny beats an allow only on the identical path, and the templated allow is more specific than any prefix deny (found in review). Vault's ServiceAccount gets `get` on namespaces to read the label.
- **Cleanup:** the operator's finalizer `idp.ithaca-idp.com/workload-vault-purge` deletes `kv/<ns>/<workload>/` when the WorkloadIdentity is deleted.
- **Hostnames:** `<workload>.<ns>.apps.ithaca-idp.com` (two labels; a user decision, so a namespace can host several workloads under one DNS subtree).
- **Proof:** `scripts/vault-proof.sh` P8 proves the role (own path readable, other name and other namespace denied, an unlabelled namespace cannot log in); `verify.sh` step 7 checks the objects and the SPIFFE ID in the smoke namespace.

## Consequences

- Isolation is across namespaces, not within one. A tenant admin can mint `vault-reader` tokens that read `kv/<ns>/*`, and a ServiceAccount named like a workload reads that workload's path. Every ServiceAccount that logs in creates a Vault entity.
- Platform namespaces cannot log in with `workload-reader` at all (no label, no login).
- Vault-side changes only reach a Vault configured after this change (the config Job configures a fresh Vault), so they arrive with the next `make down` / `make up`.

## Open items (not decided)

- **HTTPS for the two-label hostnames: decided, not built.** The wildcard certificate (`*.apps.ithaca-idp.com`) covers one label, so `<workload>.<ns>.apps...` fails TLS. DNS and the listener already match several labels (`a.b.apps.ithaca-idp.com` resolves to the ingress IP and the `*.apps` listener hostname matches it), so the only gap is the certificate.
  - **Tried and rejected (2026-11-05): a second certificate on the same listener.** idp-gitops #38 added `tenant-apps-tls` as a second `certificateRef` on the `https` listener (Istio accepts at most two). It did not work on Istio 1.27.1: istiod refused SDS with `attempted to access unauthorized certificates wildcard-apps-tls, tenant-apps-tls: cross namespace secret reference requires ReferenceGrant` (both Secrets are in the gateway's namespace), `tenant-apps-tls` stayed WARMING in Envoy, and a gateway restart would also have lost `wildcard-apps-tls`. Reverted in idp-gitops #39. SNI selection between two certificates was therefore never shown.
  - **Decision (option 2b): one certificate, one `certificateRef`.** The platform Certificate `wildcard-apps` keeps `*.apps.ithaca-idp.com` and gains one `*.<ns>.apps.ithaca-idp.com` per managed namespace. The operator edits only `spec.dnsNames` of that one Certificate (RBAC with `resourceNames`, and an admission policy that pins the allowed names to `*.apps.ithaca-idp.com` plus `*.<managed namespace>.apps.ithaca-idp.com`); Argo CD gets `ignoreDifferences` on `spec.dnsNames` so self-heal does not undo it. No Gateway edit rights, no listener cap (a Gateway allows 64 listeners), up to 100 names per certificate (Let's Encrypt).
  - **Costs and limits:** every namespace added or removed reissues the certificate (DNS-01, a minute or two before HTTPS works for a new namespace); a failed issuance must not break the existing names (cert-manager keeps serving the old Secret). Let's Encrypt prod limits (50 new certificates per registered domain per week, 5 duplicates) matter once the staging issuer is replaced, ADR 0006. The `make down` / `make up` cycle starts from the namespaces that exist then.
  - **Fallback (option 1):** a listener per namespace with its own `certificateRef`; needs operator rights on the shared Gateway and is capped at 64 listeners.
- **Gateway traffic, built:** idp-portal #28 adds NetworkPolicy `idp-allow-ingress-gateway` (TCP 15008 from the `istio-ingress` gateway pods) to every tenant namespace; end-to-end reachability is not yet proven because no workload sits behind a route.
- **Follow-ups from the reviews:** tenants can create cert-manager Issuers with an http01 gateway solver (`admin` aggregates cert-manager-edit); pin the deny and same-namespace NetworkPolicy specs in the operator admission policy.
- **GCP Workload Identity (KSA to GSA binding)** is deferred: it needs IAM in this repo and an Opus review.
