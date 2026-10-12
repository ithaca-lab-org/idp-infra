# gke

Zonal GKE **Standard** cluster (never Autopilot or regional) on the REGULAR channel with:

- Dataplane V2, Gateway API (standard channel), Workload Identity
- private nodes; reach the API through the IAM-gated DNS endpoint (`gcloud container clusters get-credentials --dns-endpoint`). `authorized_networks` is optional and only affects the public IP endpoint
- a firewall rule letting the control plane reach admission webhooks (istiod 15017, Kyverno 9443)
- application-layer secrets encryption with the KMS key from `modules/kms`
- one Spot `e2-standard-4` pool, autoscaling 1-4 (never 0: system pods need a node to recover after preemption), a dedicated least-privilege node service account
- `deletion_protection = false` so `make down` works

Registry pull access is granted per repository in `envs/dev`. Spot nodes can be preempted at any time: run workloads with PodDisruptionBudgets and at least 2 nodes.
