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
