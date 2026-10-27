# Tailscale operator: prerequisites and secrets

The Tailscale Kubernetes operator gives private tailnet access to admin UIs (Argo CD, later Grafana,
Vault, Keycloak) so they need no public load balancer (ADR 0005). It is installed by Argo CD from
`idp-gitops` (`apps/tailscale-operator.yaml`, sync-wave 2). Its OAuth credentials are the one
bootstrap secret that cannot come from Git, so `make up` copies them from Google Secret Manager.

## One-time manual setup

1. **Tailscale account and tailnet.** A free personal tailnet is enough.
2. **Tags in the tailnet policy file** (admin console > Access controls). The operator runs as
   `tag:k8s-operator` and tags the proxies it creates `tag:k8s`, so it must own that tag:

   ```jsonc
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"],
   },
   ```

   If the policy no longer allows everything by default, also add a grant that lets your own devices
   reach `tag:k8s` (for example `{"src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["*"]}`).
3. **OAuth client** (admin console > Settings > Trust credentials / OAuth clients) with scopes
   **Devices Core: write** and **Auth Keys: write**, and tag **`tag:k8s-operator`**. The client secret
   is shown once.
4. **Store both values in Secret Manager** in project `project-324502ff-9928-4b17-a89`. Paste them
   at a silent prompt (these commands work in bash and zsh) so they never reach shell history or the process list:

   ```bash
   P=project-324502ff-9928-4b17-a89
   for s in tailscale-oauth-client-id tailscale-oauth-client-secret; do
     gcloud secrets create "$s" --replication-policy=automatic --project="$P"
     printf '%s: ' "$s"; stty -echo; IFS= read -r v; stty echo; echo
     printf '%s' "$v" | gcloud secrets versions add "$s" --data-file=- --project="$P"
     unset v
   done
   ```

   The Secret Manager API is already enabled by `bootstrap/`. Whoever runs `make up` needs
   `roles/secretmanager.secretAccessor` on these two secrets (project owners already have it).

| Secret Manager secret | Kubernetes Secret key | Override env var |
|---|---|---|
| `tailscale-oauth-client-id` | `client_id` | `TS_OAUTH_CLIENT_ID_SECRET` |
| `tailscale-oauth-client-secret` | `client_secret` | `TS_OAUTH_CLIENT_SECRET_SECRET` |

## How the secret reaches the cluster

The cluster is rebuilt on every `make up`, so a Kubernetes Secret does not survive `make down`.
`make up` runs, in order:

1. `scripts/precheck.sh`, `terraform init`, `terraform apply` (cluster, Argo CD, root Application).
   Argo CD immediately starts syncing the waves from `idp-gitops`.
2. **`scripts/bootstrap-secrets.sh`**: reads `latest` of both Secret Manager secrets, gets cluster
   credentials through the DNS endpoint, ensures namespace `tailscale`, and creates or updates Secret
   `tailscale/operator-oauth` with keys `client_id` and `client_secret`. Values never touch argv,
   stdout or Git. It can be re-run on its own at any time.
3. `scripts/verify.sh`: all Argo CD apps Synced/Healthy, then `deployment/operator` in `tailscale`
   Available.

The chart (pinned in `idp-gitops`) leaves `oauth.clientId`/`oauth.clientSecret` empty, so it creates no
Secret of its own and mounts `operator-oauth` at `/oauth`. If Argo CD gets to wave 2 before step 2,
the operator Pod waits in `ContainerCreating` until the Secret appears and then starts by itself.

The namespace has no `istio.io/dataplane-mode` label: the operator and its proxy Pods stay outside the
Istio ambient mesh.

## Rotation

1. Create a new OAuth client with the same scopes and tag (or generate a new secret on the existing one).
2. Add a new version to each changed secret (same silent-prompt / `versions add` commands as above).
3. If the cluster is up: `./scripts/bootstrap-secrets.sh`, then restart the operator so it reads the new
   files: `kubectl -n tailscale rollout restart deployment/operator`. Otherwise the next `make up` picks
   the new version up.
4. Revoke the old OAuth client in the Tailscale admin console, then disable the old secret versions
   (`gcloud secrets versions disable <n> --secret=<name> --project=...`).

Proxies already on the tailnet keep their own node keys; rotating the OAuth client only affects the
operator's ability to create new devices and auth keys.

## Teardown note

The operator's device state lives in the in-cluster Secret `tailscale/operator`, which `make down`
destroys. Each `make up` therefore registers a new `ithaca-idp-operator` device. Remove stale devices
from the admin console (Machines) after `make down`, or the new one gets a numbered hostname suffix.

## Later

External Secrets Operator with a Secret Manager `ClusterSecretStore` (Workload Identity, no keys)
replaces `bootstrap-secrets.sh` in a later phase (ADR 0005).

## Stale devices (cleaned automatically)

The operator registers a tailnet device for itself and one per proxy (`keycloak-admin`, `lldap-admin`, `argocd-admin`). Destroying the cluster leaves them behind, offline, and the next cluster's proxies then get `-1`, `-2` suffixes, which breaks the Keycloak admin URL (`KC_HOSTNAME_ADMIN` is built from the unsuffixed name).

`scripts/tailscale-cleanup.sh` deletes the project's devices through the Tailscale API with the operator's own OAuth client. A device is only touched if it carries `tag:k8s` or `tag:k8s-operator` **and** its hostname matches `TS_CLEANUP_HOSTNAMES` (default: `ithaca-idp-operator`, `keycloak-admin`, `lldap-admin`, each with an optional `-N` suffix). Add a hostname to that pattern when you add a new Tailscale Ingress.

- `make down` runs it with `--delete --include-online` after a successful destroy: the destroyed devices still look online for a few minutes, and the cluster is known to be gone.
- `make up` runs it with `--delete --if-no-cluster` before building: it does nothing if the GKE cluster exists, so a re-run against a live cluster cannot remove its proxies; otherwise it clears whatever a failed earlier `make down` left. It still skips anything that looks online.
- Dry run first: `make tailscale-cleanup` lists the candidates and deletes nothing. `make tailscale-cleanup DELETE=1` deletes them.
- A device whose `lastSeen` cannot be parsed counts as online and is skipped. It refuses to delete more than 50 devices, or any device with an unexpected id format.
- The OAuth client needs the scope **Devices Core: write** (the same scope the operator needs). If a delete returns HTTP 403, check the scope, and that the client's tag `tag:k8s-operator` owns `tag:k8s` in the policy file (section 2 above).
- Failure never fails `make down` or `make up`: it prints a message, and you delete the entries in the admin console under Machines.
