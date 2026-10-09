# network

VPC with one subnet (secondary ranges for pods and services), Cloud Router and Cloud NAT. Nodes are private; NAT gives them outbound internet for image pulls.

| Variable | Default | Notes |
|---|---|---|
| `name` | required | prefix for all resources |
| `region` | required | |
| `nodes_cidr` / `pods_cidr` / `services_cidr` | `10.10.0.0/20` / `10.20.0.0/16` / `10.30.0.0/20` | |

Outputs: `network_id`, `subnetwork_id`, `pods_range_name`, `services_range_name`.
