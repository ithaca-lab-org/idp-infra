# 0008. Vault listener TLS from an in-cluster cert-manager CA

- Status: accepted
- Date: 2026-10-31

## Context

Vault's listener was plain HTTP inside the cluster (`tls_disable = 1`), fenced only by NetworkPolicies. Secret values travel to Vault from the portal Secrets page (portal-api writes), out of it to VSO (reads into tenant Secrets), and every VaultAuth login carries a ServiceAccount JWT. None of these namespaces is in the ambient mesh, so nothing encrypted that traffic; this was a recorded accepted risk.

Vault's names (`vault.vault.svc.cluster.local`, per-pod names, `127.0.0.1`) are cluster-internal, so a public CA (Let's Encrypt) cannot issue for them. The cluster and Vault are rebuilt on every `make up`. Clients live in four namespaces: `vault` (in-pod CLI, config Job), `vault-secrets-operator` (VSO; tenants and `vault-demo` share its VaultConnection), `idp-system` (portal-api, idp-operator) and `tailscale` (the `vault-admin` proxy).

## Decision

- **CA:** cert-manager (already at wave 1) issues from a self-signed root CA `cert-manager/vault-ca` (ECDSA P-256, 10 years) through `ClusterIssuer vault-ca`. The CA key stays in the cert-manager namespace.
- **Server certificate:** `vault/vault-server-tls`, 30 days, renewed 20 days before expiry (after 10 days), new key each time. SANs: all chart Services (short and long forms), `*.vault-internal...` (per-pod, `api_addr`), `localhost`, `127.0.0.1`, `::1`. The listener is TLS 1.3 only (all clients are Go).
- **Reload:** Vault reloads listener certificates on SIGHUP, not on file change. A `tls-reload` sidecar in the Vault pod (same image and UID, shared process namespace, no extra capability) sends SIGHUP to the `vault server` process (checked by its cmdline, never a `kubectl exec` CLI) when the mounted `tls.crt` changes. `verify.sh` step 8 fails if the served certificate differs from the Secret, so a failed reload is caught with 20 days to spare. Restarting instead would need a restart controller or exec rights, and a restart briefly drops the only Vault replica.
- **CA distribution without trust-manager:** each client namespace outside `vault` gets a throwaway Certificate `vault-ca-bundle` from the same ClusterIssuer, only for the `ca.crt` cert-manager writes into every issued Secret. Its leaf is client-auth only with no SANs; pods mount the `ca.crt` key only. Only `vault-secrets-operator` and `idp-system` need one: VSO reads `caCertSecretRef` in the VaultConnection's namespace, so tenants and `vault-demo` (switched to the shared connection) need nothing.
- **Fence the ClusterIssuer:** tenants are namespace `admin`, which cert-manager aggregates Certificate create into, so they could otherwise mint a certificate for Vault's names that every client trusts. A ValidatingAdmissionPolicy `vault-ca-scope` denies Certificates and CertificateRequests for `ClusterIssuer vault-ca` outside `vault`, `vault-secrets-operator` and `idp-system`, and outside `vault` requires `isCA: false` and explicit usages without `server auth`/`any`; `vault-ca-bundle-sans` forbids DNS, IP and URI SANs on such Certificates (a CertificateRequest's SANs are in its CSR, which CEL cannot read).
- **Clients trust only this CA for Vault:** portal-api and idp-operator read `VAULT_CACERT` (new in idp-portal) into a pool without system roots; VSO uses `caCertSecretRef`; the in-pod CLI and the config Job use `VAULT_CACERT`. The Tailscale proxy speaks `https+insecure` (its operator has no CA setting): encrypted, not verified, and it reaches Vault by ClusterIP from a namespace NetworkPolicies already restrict.
- **Ordering:** inside the vault app, sync waves -4..-1 create the policy, CA, ClusterIssuer and server certificate before the chart (wave 0), and Argo CD waits for each to be Healthy, so a missing certificate shows as "no vault-0" with a hint from `bootstrap-secrets.sh`, not a crash loop.

## Alternatives

- **trust-manager:** the standard tool for CA distribution, but one more controller with Secret read in its trust namespace, for two namespaces. Revisit when more consumers appear.
- **A namespaced CA Issuer in `vault` only:** no ClusterIssuer to fence, but then no way to get `ca.crt` into other namespaces without a copy job (cross-namespace Secret write RBAC) or the laptop script copying it (not GitOps, lost when a namespace is recreated).
- **`SSL_CERT_FILE`/`SSL_CERT_DIR` in portal-api and the operator:** no code change, but it trusts the in-cluster CA for every host and (with `SSL_CERT_FILE`) drops the public roots portal-api needs for Keycloak and Pub/Sub.
- **Istio ambient mTLS for the Vault namespace:** encrypts pod-to-pod, but VSO, the Tailscale proxy and the in-pod CLI path would still be plaintext at the listener, and Vault's availability would depend on the mesh.

## Consequences

- Secret values and login JWTs are encrypted in transit and every client except the Tailscale proxy verifies Vault's identity.
- One more container in the Vault pod (~8 MiB) and a shared process namespace: the sidecar can see Vault's processes (same UID). It runs only the server image's busybox.
- Clients read the CA once at start: if `cert-manager/vault-ca` is ever re-issued (not on renewal of the server certificate), restart VSO, portal-api and idp-operator. A rebuild re-creates everything anyway.
- The idp-portal images must support `VAULT_CACERT` before idp-gitops switches to https: merge idp-portal first, then bump the pins with the TLS change.
- `verify.sh` step 8 asserts the TLS listener, that the served certificate is the one in the Secret, and that plain HTTP is refused.
- **Rollout onto a running cluster:** the chart's StatefulSet has `updateStrategy: OnDelete`. Merging the idp-gitops change onto a running cluster switches VSO, portal-api and idp-operator to https while the old plain-HTTP `vault-0` keeps running, so they fail until a human runs `kubectl -n vault delete pod vault-0`. Recommended: merge right before `make down` / `make up`.
- **Tailscale `vault-admin` hop:** the proxy uses `https+insecure` (encrypted, Vault's certificate not verified). An attacker able to intercept traffic to Vault's ClusterIP inside the cluster could read admin UI traffic on that hop; accepted because the proxy dials the ClusterIP directly from a namespace the NetworkPolicies restrict, and the Tailscale operator offers no CA setting.
