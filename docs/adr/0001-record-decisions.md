# 0001. Record architecture decisions

- Status: accepted
- Date: 2026-10-07

## Context

The IDP makes many trade-offs (cost vs. realism, Spinnaker vs. Argo, Standard vs. Autopilot). The reasoning is easy to lose and is exactly what reviewers ask about.

## Decision

Record each significant decision as a short ADR in `docs/adr/`, numbered in order, using Context / Decision / Consequences. ADRs are immutable once accepted; a later decision supersedes by reference.

Planned: 0002 GKE Standard zonal with Spot, 0003 GitOps with Argo CD, plus one for the plan/apply identity split (separate read-only and apply service accounts, apply limited to `main`).

## Consequences

Small writing cost per decision; decisions stay explainable and reviewable in PRs.
