# Vault (Phase 1b): self-hosted, Cloud KMS auto-unseal

Vault holds developer app secrets (and later dynamic database credentials); VSO syncs them into Kubernetes Secrets (`IDP_NOTES.md` section 10). This repo provides the cloud side and the one-time init; `idp-gitops` installs and configures Vault.

## Architecture

```
envs/persistent (CI)                  idp-gitops (Argo CD)                    make up (human)
  KMS key ring idp                      namespace vault                         scripts/bootstrap-secrets.sh
    key vault-unseal  <── gcpckms ───   Helm release vault (1 Raft node)          vault operator init (once)
  GSA vault  <── Workload Identity ──   KSA vault/vault                            -> Secret Manager
                                        config Job (waits for vault-bootstrap)     -> Secret vault/vault-bootstrap
                                        VSO -> Secret vault-demo/hello
```

- **Seal:** `seal "gcpckms"` with key `vault-unseal` in the existing `idp` key ring (same location as `gke-secrets`). Software protection, 90-day rotation (old versions keep decrypting), `prevent_destroy`. Vault unseals itself on every start; nobody types unseal keys. `vault operator init` therefore returns **recovery keys** (3 shares, threshold 2), not unseal keys.
- **Identity:** the Vault pod runs as KSA `vault/vault`, which impersonates GSA `vault@<project>.iam.gserviceaccount.com` through Workload Identity. No JSON key.
- **Storage:** integrated Raft on the pod's PVC. The PVC dies with the cluster (`make down`).
- **Terraform** (`modules/vault-unseal`): the key, the GSA, and three grants, none at project or key-ring level:

| Member | Role | On |
|---|---|---|
| GSA `vault` | `roles/cloudkms.cryptoKeyEncrypterDecrypter` | key `vault-unseal` only |
| GSA `vault` | `roles/cloudkms.viewer` (the seal needs `cloudkms.cryptoKeys.get`) | key `vault-unseal` only |
| KSA `vault/vault` (project pool `<project>.svc.id.goog`) | `roles/iam.workloadIdentityUser` | GSA `vault` only |

- **Outputs** of `envs/persistent` for the Helm values: `vault_kms_project`, `vault_kms_location`, `vault_kms_key_ring`, `vault_kms_crypto_key`, `vault_sa` (KSA annotation `iam.gke.io/gcp-service-account`).

## Who holds what

| Item | Where | Lifetime |
|---|---|---|
| KMS key `vault-unseal` | Cloud KMS (persistent stack) | Permanent; cannot be deleted, only its versions scheduled for destruction |
| Root token | Secret Manager `vault-root-token` and Secret `vault/vault-bootstrap` key `root-token` | Short: the `idp-gitops` config Job uses it, then **revokes it**. Both copies are dead afterwards |
| Recovery keys (3, threshold 2) | Secret Manager `vault-recovery-keys` (JSON: `recovery_keys_b64`, `recovery_keys_hex`, shares, threshold) | As long as this Vault lives (until the next `make down`) |
| App secrets | Vault KV (`kv/<ns>/...`), copied by VSO into namespace Secrets | Until the next `make down` (see follow-ups) |

Neither secret is in Terraform (CI's apply identity cannot write Secret Manager). `bootstrap-secrets.sh` creates them on first use (needs `roles/secretmanager.admin` the first time, then `secretAccessor` plus version add). The values never reach the terminal, argv, logs or Git: the init output lives only in a 0600 file in the script's private temp dir, which is deleted on exit.

## Init flow (every `make up`)

1. `bootstrap-secrets.sh` checks whether Argo CD deploys the `vault` Application. If the root app `argocd-root` does not list it, the script prints a notice and skips (not a failure). If it is listed but not created yet (earlier sync waves), it waits up to `VAULT_APP_TIMEOUT` (900 s).
2. It waits up to `VAULT_POD_TIMEOUT` (600 s) for `vault-0` to be Running with its API answering (`vault status` exit code 0 = unsealed, 2 = sealed or uninitialized, 1 = error).
3. Already initialized: nothing is changed. If it is initialized but still sealed after `VAULT_UNSEAL_TIMEOUT` (120 s), it fails: auto-unseal is broken (see Troubleshooting).
4. Not initialized: it creates the two Secret Manager secrets if missing (before init, so a permission problem cannot lose the output), runs `vault operator init -recovery-shares=3 -recovery-threshold=2`, adds new versions of `vault-root-token` and `vault-recovery-keys`, creates `vault/vault-bootstrap`, and waits for Vault to report unsealed.
5. The config Job (`idp-gitops`) waits for `vault/vault-bootstrap`, enables KV, Kubernetes auth, policies and the demo (`kv/vault-demo/hello`), then revokes the root token.
6. `verify.sh` step 8 checks `vault-0`, `Initialized true` / `Sealed false`, and that VSO synced Secret `vault-demo/hello` (key `message`; the value is never printed).

**Rebuilds:** Vault's data dies with the cluster, so each `make up` initializes a brand-new Vault. Every rebuild adds a new version to both Secret Manager secrets; older versions belong to a destroyed Vault and are useless (disable or destroy them whenever convenient: `gcloud secrets versions disable <n> --secret=vault-recovery-keys`). Only `latest` matters. KV data written by hand is lost too: anything that must survive belongs in Git (config Job) or in the portal flow that writes it again.

## Getting an admin token later

The root token is revoked by the config Job. To get a new one, two of the three recovery keys are needed (`generate-root` with an auto-unseal Vault takes recovery keys):

```sh
kubectl -n vault exec -it vault-0 -- vault operator generate-root -init
# note the Nonce and the OTP it prints
gcloud secrets versions access latest --secret=vault-recovery-keys | jq -r '.recovery_keys_b64[0]' \
  | kubectl -n vault exec -i vault-0 -- vault operator generate-root -nonce=<nonce> -
gcloud secrets versions access latest --secret=vault-recovery-keys | jq -r '.recovery_keys_b64[1]' \
  | kubectl -n vault exec -i vault-0 -- vault operator generate-root -nonce=<nonce> -
# the second call prints "Encoded Token"
kubectl -n vault exec -it vault-0 -- vault operator generate-root -decode=<encoded token> -otp=<otp>
```

Use the token for the task at hand, then revoke it (`vault token revoke -self`). Cancel an unfinished attempt with `vault operator generate-root -cancel`. Prefer a scoped admin policy over root for anything regular.

## Troubleshooting

- **Initialized but sealed** (`bootstrap-secrets.sh` or `verify.sh` fails with the KMS hint): `kubectl -n vault logs vault-0`. `PermissionDenied` on the key means the GSA grants or the Workload Identity binding are missing (was `envs/persistent` applied?), or the KSA lacks the `iam.gke.io/gcp-service-account` annotation. Wrong project/location/ring/key in the seal stanza shows as `NotFound`.
- **Init output lost** (the script failed after init but before both secrets were stored, or was interrupted): this Vault cannot be administered. Wipe it and re-run: delete the StatefulSet's PVC `data-vault-0` and the pod `vault-0` (human step; Argo CD recreates them), then `./scripts/bootstrap-secrets.sh`. On a lab rebuild, `make down` / `make up` does the same.
- **The config Job never finishes:** it waits for `vault/vault-bootstrap`; re-run `./scripts/bootstrap-secrets.sh` once `vault-0` is Running.

## License

Vault 1.15 and later (community edition included) is under the Business Source License 1.1 (BUSL), not an OSI open-source license. Running it to protect our own lab platform is permitted; offering Vault itself as a competing hosted service is not. OpenBao (the MPL-2.0 fork, same API and `gcpckms` seal) is the drop-in alternative if that ever matters.

## Follow-ups (not in Phase 1b)

- **Raft snapshots to GCS** on a schedule (a CronJob with a snapshot-only policy and a bucket-scoped GSA), so KV data can survive a rebuild via `vault operator raft snapshot restore`.
- **TLS on the Vault listener** with a cert-manager Certificate (in-cluster CA); until then the listener is plain HTTP, reachable in-cluster only.
- **Cloud SQL is out of scope**: databases stay in-cluster (CloudNativePG) with Vault dynamic credentials (section 10.4).
