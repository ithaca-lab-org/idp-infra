# Identity bootstrap secrets

`make up` runs `scripts/bootstrap-secrets.sh`, which also prepares the identity stack that `idp-gitops` deploys (waves 8-9: lldap, Keycloak and its Postgres).

| Secret Manager name | Kubernetes Secret | Used by |
|---|---|---|
| `lldap-admin-password` | `identity/lldap` key `admin-password` | lldap admin, Keycloak LDAP bind |
| `lldap-jwt-secret`, `lldap-key-seed` | `identity/lldap` keys `jwt-secret`, `key-seed` | lldap token signing |
| `keycloak-admin-password` | `identity/keycloak-admin` key `password` | Keycloak bootstrap admin (user `admin`) |
| `keycloak-db-password` | `identity/keycloak-db` key `password` | Keycloak Postgres and Keycloak DB login |

- On the first run the script **generates** any missing secret (random 64-char hex) in Secret Manager. Values never appear on the terminal, in Terraform state or in Git. Later runs only read them, so the passwords survive `make down` / `make up`.
- It needs `roles/secretmanager.admin` the first time (to create) and `roles/secretmanager.secretAccessor` after.
- Read a value yourself when you need to log in: `gcloud secrets versions access latest --secret=keycloak-admin-password`.
- To rotate, add a new version in Secret Manager and re-run the script; the pods read the Secret at start, so restart them (or run `make down` / `make up`).
- External Secrets replaces this script in a later phase (ADR 0005).

## Exposure and the optional `tailnet-domain` secret

Public: only `https://auth.apps.ithaca-idp.com/realms/ithaca/*` and `/resources/*` (ADR 0007). Private: the Keycloak admin console (`https://keycloak-admin.<tailnet>.ts.net`) and the lldap UI (`https://lldap-admin.<tailnet>.ts.net`), through the Tailscale operator.

Keycloak must know its admin URL, and the tailnet name is kept out of this public repo. Store it once, then the next `make up` (or `./scripts/bootstrap-secrets.sh`) sets `KC_HOSTNAME_ADMIN`:

```bash
P=project-324502ff-9928-4b17-a89
gcloud secrets create tailnet-domain --replication-policy=automatic --project="$P"
printf 'tailnet domain (for example tail1234.ts.net): '; read -r v
printf '%s' "$v" | gcloud secrets versions add tailnet-domain --data-file=- --project="$P"
```

Without it the script prints a notice and the admin console is only reachable through `kubectl -n identity port-forward svc/keycloak-http 8080:80`.
