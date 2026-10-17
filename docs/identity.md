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
