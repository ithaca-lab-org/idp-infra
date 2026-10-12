# 0002. GKE Standard, zonal, Spot, Dataplane V2

- Status: accepted
- Date: 2026-10-10

## Context

The IDP must be cheap to run (budget-first), rebuildable on demand (`make up` / `make down`), and realistic enough to show production patterns: private nodes, Workload Identity, secrets encryption, a service mesh and policy enforcement.

## Decision

- **GKE Standard, one zone** (`us-central1-a`), REGULAR release channel. A zonal cluster is covered by the GKE free-tier management credit; Autopilot and regional clusters are ruled out (cost, and Autopilot restricts the node-level features the platform uses).
- **One Spot `e2-standard-4` pool, autoscaling 1-4.** Spot keeps nodes at a fraction of on-demand price. The minimum is 1, never 0: with zero nodes, system pods (DNS, konnectivity) cannot recover after a preemption.
- **Dataplane V2** (`ADVANCED_DATAPATH`) for NetworkPolicy and observability. It cannot be changed without rebuilding the cluster, so it was verified against the mesh before being accepted (below).
- **Private nodes + Cloud NAT**, API reached through the IAM-gated DNS endpoint rather than IP allowlists (laptop and CI IPs change).
- **Workload Identity**, Gateway API (standard channel, CRDs owned by GKE), application-layer secrets encryption with a KMS key kept in the persistent stack (ADR 0004).

## Verification: Istio ambient on Dataplane V2

The main risk was that Dataplane V2 (Cilium) could route Service ClusterIP traffic around ztunnel, so mesh policy would silently not apply. `scripts/smoke-ambient.sh` (Istio 1.27.1) was run on a `make up` cluster on 2026-10-10 and passed all five checks:

1. Pods have no sidecars; ztunnel and istio-cni are Ready on every node.
2. Calls to a ClusterIP DNS name travel over HBONE.
3. An L4 AuthorizationPolicy allowing only one service account is enforced on ClusterIP traffic: the allowed client succeeds and a second client is denied. This is the decisive check.
4. A NetworkPolicy allowing only HBONE (15008) and the probe address keeps the mesh working and the denied client denied.
5. A waypoint (Gateway API) performs L7 header routing.

## Consequences

- Ambient mode (no sidecars) is the mesh choice for Step 6; `idp-gitops` can proceed with Istio ambient.
- Spot preemption of the only node causes a short outage until the autoscaler provisions a replacement. Acceptable for a lab; the demo should show self-healing, not hide it.
- Changing the datapath, private-cluster settings or `master_ipv4_cidr_block` later means recreating the cluster.
- Default-deny NetworkPolicies must allow the probe address `169.254.7.127/32` (see `docs/smoke-ambient.md`).
- Not covered by the smoke test: behaviour under node preemption, and multi-node placement beyond the nodes the test ran on.
