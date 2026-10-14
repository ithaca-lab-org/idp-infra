# 0006. Let's Encrypt staging by default

- Status: accepted
- Date: 2026-10-14

## Context

The wildcard certificate for `*.apps.ithaca-idp.com` is issued by Let's Encrypt over DNS-01. The cluster is rebuilt often (`make up` / `make down`), and the certificate Secret lives in the cluster, so every rebuild requests a new certificate for the same names. Let's Encrypt production allows only 5 duplicate certificates per week for an identical set of names; a handful of rebuilds would block issuance for days.

## Decision

- The `wildcard-apps` Certificate uses the `letsencrypt-staging` ClusterIssuer by default. Staging has far higher limits.
- Both issuers exist (`letsencrypt-staging`, `letsencrypt-prod`). To demo a browser-trusted certificate, change `issuerRef.name` in `idp-gitops/workloads/ingress/certificate.yaml` to `letsencrypt-prod`, merge, and switch back afterwards.
- `scripts/verify.sh` detects the staging issuer, uses `curl -k`, and prints that TLS trust was not checked.
- The ACME contact address is a placeholder (`admin@ithaca-idp.com`) because the repos are public; no expiry mail is received, which is acceptable because certificates are reissued on every rebuild.

## Consequences

- Browsers show a certificate warning on the default build; HTTP checks and mesh behaviour are unaffected.
- Considered and deferred: persisting the issued certificate in Secret Manager and restoring it on `make up`, which would make production certificates safe to use on every rebuild (and keep one valid certificate per 60 days instead of one per rebuild).
- Rate-limit headroom is the constraint to watch when switching to production for demos: do it deliberately and avoid repeated rebuilds that week.
