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

- **HTTPS for the two-label hostnames.** The wildcard certificate (`*.apps.ithaca-idp.com`) covers one label only, so `<workload>.<ns>.apps...` is not covered. HTTPS needs, per namespace: a certificate for `*.<ns>.apps.ithaca-idp.com`, a Cloud DNS wildcard record to the ingress IP, and a Gateway listener with its own `certificateRef`. Something must create them. Giving the operator rights on the shared Gateway is a security trade-off; Let's Encrypt rate limits apply (use the staging issuer first, ADR 0006). Until then the HTTPRoute only reserves the hostname (it has no backend).
- **Gateway traffic is still blocked** by the default-deny NetworkPolicy; an allow rule for the ingress gateway towards labelled workload pods is a follow-up.
- **GCP Workload Identity (KSA to GSA binding)** is deferred: it needs IAM in this repo and an Opus review.
