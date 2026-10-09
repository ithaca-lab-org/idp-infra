# gke

Zonal GKE **Standard** cluster (never Autopilot or regional) on the REGULAR channel with:

- Dataplane V2, Gateway API (standard channel), Workload Identity
- private nodes, public endpoint restricted by `authorized_networks`
- application-layer secrets encryption with the KMS key from `modules/kms`
- one Spot `e2-standard-4` pool, autoscaling 0-4, a dedicated least-privilege node service account
- `deletion_protection = false` so `make down` works

To use `kubectl` from your laptop, add your IP to `authorized_networks` (see `envs/dev/terraform.tfvars`). Spot nodes can be preempted at any time: run workloads with PodDisruptionBudgets and at least 2 nodes.
