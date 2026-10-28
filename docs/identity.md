# Identity bootstrap secrets

`make up` runs `scripts/bootstrap-secrets.sh`, which also prepares the identity stack that `idp-gitops` deploys (waves 8-9: lldap, Keycloak and its Postgres).

| Secret Manager name | Kubernetes Secret | Used by |
|---|---|---|
| `lldap-admin-password` | `identity/lldap` key `admin-password` | lldap admin, Keycloak LDAP bind |
| `lldap-jwt-secret`, `lldap-key-seed` | `identity/lldap` keys `jwt-secret`, `key-seed` | lldap token signing |
| `keycloak-admin-password` | `identity/keycloak-admin` key `password` | Keycloak bootstrap admin (user `admin`) |
| `keycloak-db-password` | `identity/keycloak-db` key `password` | Keycloak Postgres and Keycloak DB login |
| `lldap-seed-users-password` | `identity/lldap-seed-users` key `password` | One shared password for the seeded dev users (see below) |
| `portal-session-key` | `idp-system/portal-session` key `session-key` | Portal session cookie signing key |
| `portal-mongo-root-password`, `portal-mongo-password` | `idp-system/portal-mongo` keys `root-password`, `app-password` | Portal MongoDB: root only initialises the database, the API uses the `portal` user |
| `resend-api-key` (optional, never generated) | `idp-system/notifier-resend` key `api-key` | Notifier email via Resend; skipped until a human creates it and adds a version, see `docs/order-events.md` |
| `vault-recovery-keys` (written by the script, never generated) | none (the 30-minute bootstrap token in `vault/vault-bootstrap` key `token` is minted, not copied) | Vault recovery keys from `vault operator init`, a new version on every rebuild; only when the `vault` app is deployed. The root token is never stored. See `docs/vault.md` |

- On the first run the script **generates** any missing secret (random 64-char hex) in Secret Manager. Values never appear on the terminal, in Terraform state or in Git. Later runs only read them, so the passwords survive `make down` / `make up`.
- It needs `roles/secretmanager.admin` the first time (to create) and `roles/secretmanager.secretAccessor` after.
- Read a value yourself when you need to log in: `gcloud secrets versions access latest --secret=keycloak-admin-password`.
- **Rotation needs more than a new Secret Manager version.** The services only read these values when they first initialise their data: Postgres (`POSTGRES_PASSWORD`), Keycloak (`KC_BOOTSTRAP_ADMIN_PASSWORD` and the LDAP bind password stored in its database), and lldap (`LLDAP_LDAP_USER_PASS`). Adding a version and restarting pods does not revoke the old value, and leaves Keycloak unable to reach Postgres or LDAP. After a suspected leak, rebuild (`make down`, then `make up`), or change the password inside each running service first (`ALTER ROLE`, `kcadm.sh set-password`, the lldap UI) and then add the new Secret Manager version. Do not rotate `lldap-key-seed` on a cluster with users: every lldap password becomes invalid.
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

## Seeded dev users

On every rebuild an Argo CD post-sync Job (`idp-gitops` `workloads/identity/lldap-seed.yaml`) creates three groups (`cloudspend-bu`, `supplychain-bu`, `marketing-northeast-bu`) and seven fixture users (`user01` to `user07`) in lldap, with their group memberships, using lldap's own bootstrap script. The definitions live in the ConfigMaps in that file; the **password is not in Git**: all seven users use the Secret Manager secret `lldap-seed-users-password`, generated at random on the first `make up`.

- Read it: `gcloud secrets versions access latest --secret=lldap-seed-users-password`
- Choose your own (at least 8 characters): `printf %s "<password>" | gcloud secrets versions add lldap-seed-users-password --data-file=-`, then run `./scripts/bootstrap-secrets.sh` or `make up`.
- The Keycloak login is public on the internet while the cluster is up: pick a password you would not mind a stranger trying, and keep the cluster up only when you need it.
- The Job only creates and updates its own users and groups; it never deletes users you create by hand.
