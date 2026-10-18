# 0007. Hybrid exposure: public OIDC endpoints, tailnet-only admin

- Status: accepted
- Date: 2026-10-17

## Context

Keycloak is the identity provider for the portal and later Grafana, Spinnaker and Argo CD. Browsers and in-cluster pods must resolve the same OIDC issuer URL, so the issuer cannot sit on a tailnet-only name without an egress proxy for every client. Reviewers should also be able to try the portal without joining the tailnet. Admin surfaces (Keycloak admin console, lldap UI) have no such need and carry the highest risk.

## Decision

- The public ingress (`*.apps.ithaca-idp.com`, one load balancer) carries only what end users need: the portal and Keycloak's `ithaca` realm endpoints (`/realms/ithaca`, `/resources`) at `auth.apps.ithaca-idp.com`.
- Public exposure is an **allow-list** (`HTTPRoute keycloak-public`). The admin console, `/admin`, the master realm and metrics have no route and return 404. `scripts/verify.sh` asserts this.
- The Keycloak admin console and the lldap UI are exposed only through Tailscale Ingresses (ADR 0005). Keycloak's public URL is fixed with `KC_HOSTNAME`; the admin URL comes from `KC_HOSTNAME_ADMIN`, built from a `tailnet-domain` Secret Manager secret so the tailnet name stays out of Git.
- Cloud Armor in front of the public ingress remains an optional toggle for later.

## Consequences

- A forged `Host` header cannot change the issuer.
- The public surface is the realm's OIDC and login pages, a known attack surface that Keycloak's brute-force protection and later Cloud Armor cover.
- Browsers only trust the public endpoints once the wildcard certificate uses the production issuer (ADR 0006).
- Without the `tailnet-domain` secret the admin console works only through `kubectl port-forward`.
