# 0004. Split persistent and ephemeral Terraform stacks

- Status: accepted
- Date: 2026-10-08

## Context

`make down` must tear the cluster down cheaply and repeatably, but some resources must survive it: KMS key rings cannot be deleted in GCP, the Artifact Registry holds images, the DNS zone's nameservers are set at the registrar, and the budget is the cost guardrail. CI also applies on merge to `main`, which would start billing for a cluster as a side effect of merging.

## Decision

- `envs/persistent` (KMS, registry, DNS, budget): applied by CI on merge to `main`. Never destroyed by `make down`.
- `envs/dev` (network, GKE): applied and destroyed by a human with `make up` / `make down`. CI validates it but does not plan or apply it, because it reads the KMS key created by `envs/persistent`.

## Consequences

The cost-bearing stack needs a deliberate human action. The first apply order is persistent (CI, on merge), then dev (`make up`). `envs/dev` plans only run locally with `make plan ENV=envs/dev`.

## Addendum: GKE review follow-ups (2026-10-10)

An Opus review of `modules/gke` led to: the DNS endpoint instead of IP allowlists, a minimum of one Spot node (a Spot-only pool at zero nodes cannot recover), a 4h daily maintenance window (weekend-only windows fall under GKE's 48h-per-32-days rule), and a webhook firewall rule for Step 6. Open item for ADR 0002: smoke-test Istio ambient on Dataplane V2 before relying on it, since `datapath_provider` cannot change without rebuilding the cluster.
