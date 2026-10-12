# 0005. Tailscale for private access to admin UIs

- Status: accepted
- Date: 2026-10-12

## Context

The platform has several admin UIs (Argo CD now; Grafana, Vault, Keycloak, Spinnaker later) that must
not be on the public internet. The budget allows **one** load balancer, which belongs to the Istio
ingress gateway for application traffic (IDP_NOTES section 4). The cluster is rebuilt on every
`make up`, so access must come back without manual steps, and both repos are public, so no credential
may live in Git.

## Decision

- **Tailscale Kubernetes operator** (`idp-gitops`, sync-wave 2, chart pinned) exposes admin UIs on the
  tailnet through `tailscale` Ingresses / Services. The operator is tagged `tag:k8s-operator`; the
  proxies it creates are tagged `tag:k8s`, which the operator owns in the tailnet policy.
- The operator authenticates with a Tailscale **OAuth client** (scopes Devices Core write, Auth Keys
  write; tag `tag:k8s-operator`). Its id and secret live in **Google Secret Manager**
  (`tailscale-oauth-client-id`, `tailscale-oauth-client-secret`), created once by hand.
- **`make up` injects them**: `scripts/bootstrap-secrets.sh` runs after `terraform apply` and before
  `verify.sh`, and writes Secret `tailscale/operator-oauth`. The chart mounts that Secret by name and
  never sees the values. Terraform does not manage the secret, so it never enters Terraform state.
- The `tailscale` namespace stays out of the Istio ambient mesh (no `istio.io/dataplane-mode` label).
- **Later:** External Secrets Operator with a Secret Manager store over Workload Identity replaces the
  script, and the same pattern serves other platform secrets.

## Consequences

- Admin UIs cost nothing extra and are reachable only by tailnet members; there is no public attack
  surface for them.
- One imperative step remains outside GitOps (the script). It is idempotent, short, and documented in
  `docs/tailscale.md`, including rotation.
- Each rebuild registers a new operator device on the tailnet; stale devices need cleaning up.
- If Istio later enforces STRICT mTLS for workloads the Tailscale proxies talk to, those proxies (not in
  the mesh) need an explicit exception or must be enrolled; to be tested with the Istio wave.

## Alternatives considered

- **Identity-Aware Proxy (IAP):** strong Google-identity access, but needs an external HTTPS load
  balancer per backend set (cost, and a second LB beyond the budget) and only covers HTTP.
- **Cloud VPN / HA VPN:** a peer gateway at home and hourly tunnel charges; heavy for a single user.
- **Public load balancer with Cloud Armor:** admin UIs on the internet behind IP allowlists; extra LB
  cost, allowlists break on changing home IPs, and a misconfiguration exposes the UIs.
- **`kubectl port-forward` only:** free, but no stable URLs, nothing to demo, and every user needs
  cluster credentials.
