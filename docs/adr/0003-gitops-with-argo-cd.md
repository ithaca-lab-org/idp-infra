# 0003. GitOps with Argo CD

- Status: accepted
- Date: 2026-10-11

## Context

The platform has many add-ons (cert-manager, Istio, Tailscale, later Vault, Keycloak, Spinnaker, Kyverno, observability). They must install in a defined order, be reproducible on every `make up`, and be reviewable. GKE manages the nodes, so there is little for push-based tools like Ansible to configure on the cluster.

## Decision

- **Terraform installs Argo CD only** (`modules/argocd`, the one `helm_release` it owns) and creates a single root Application. Everything else is declared in the separate `idp-gitops` repo and installed by Argo CD.
- **App-of-apps with sync waves:** the root Application syncs `idp-gitops/apps/`; each child Application carries a `sync-wave` (cert-manager 1; Istio and Tailscale 2; echo app 3; later phases after that).
- **Automated sync with prune and self-heal on `main`.** A merge to `idp-gitops` is a deploy; PR review is the control.
- Upstream Helm charts are referenced with pinned versions and values live in the repo (multi-source Applications), so every change is a reviewable diff.
- `idp-gitops` is public, so Argo CD needs no repository credentials. No secrets go in it; secrets arrive via External Secrets / Vault in later phases.
- The root Application has no resource finalizer, so teardown cannot deadlock.

## Consequences

- Cluster add-ons are separated from cloud infrastructure: `idp-infra` changes rarely, `idp-gitops` changes often.
- Rebuilding is one command: `make up` applies Terraform, Argo CD pulls the repo, and the waves settle; `scripts/verify.sh` checks the result.
- Argo CD (not Terraform) is the only writer of in-cluster state, so manual `kubectl apply` is drift and will be reverted by self-heal.
- Considered and not chosen: Flux (equivalent capability, less visible UI for a portfolio demo), Helm releases from Terraform for every add-on (slow plans, no drift correction, poor ordering), Ansible for cluster config (push-based, no drift detection).
