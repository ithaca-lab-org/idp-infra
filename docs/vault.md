# Vault (Phase 1b): self-hosted, Cloud KMS auto-unseal

Vault holds developer app secrets (and later dynamic database credentials); VSO syncs them into Kubernetes Secrets (`IDP_NOTES.md` section 10). This repo provides the cloud side and the one-time init; `idp-gitops` installs and configures Vault.

## Architecture

```
envs/persistent (CI)                  idp-gitops (Argo CD)                    make up (human)
  KMS key ring idp                      namespace vault                         scripts/bootstrap-secrets.sh
    key vault-unseal  <── gcpckms ───   Helm release vault (1 Raft node)          vault operator init (once)
  GSA vault  <── Workload Identity ──   KSA vault/vault                            -> recovery keys to Secret Manager
                                        config Job (waits for vault-bootstrap)     -> Secret vault/vault-bootstrap
                                        VSO -> Secret vault-demo/hello
```

- **Seal:** `seal "gcpckms"` with key `vault-unseal` in the existing `idp` key ring (same location as `gke-secrets`). Software protection, 90-day rotation (old versions keep decrypting), `prevent_destroy`. Vault unseals itself on every start; nobody types unseal keys. `vault operator init` therefore returns **recovery keys** (3 shares, threshold 2), not unseal keys.
- **Identity:** the Vault pod runs as KSA `vault/vault`, which impersonates GSA `vault-server@<project>.iam.gserviceaccount.com` through Workload Identity. No JSON key.
- **Storage:** integrated Raft on the pod's PVC. The PVC dies with the cluster (`make down`).
- **Terraform** (`modules/vault-unseal`): the key, the GSA, and three grants, none at project or key-ring level:

| Member | Role | On |
|---|---|---|
| GSA `vault-server` | `roles/cloudkms.cryptoKeyEncrypterDecrypter` | key `vault-unseal` only |
| GSA `vault-server` | `roles/cloudkms.viewer` (the seal needs `cloudkms.cryptoKeys.get`) | key `vault-unseal` only |
| KSA `vault/vault` (project pool `<project>.svc.id.goog`) | `roles/iam.workloadIdentityUser` | GSA `vault-server` only |

- **Outputs** of `envs/persistent` for the Helm values: `vault_kms_project`, `vault_kms_location`, `vault_kms_key_ring`, `vault_kms_crypto_key`, `vault_sa` (KSA annotation `iam.gke.io/gcp-service-account`).

## Who holds what

| Item | Where | Lifetime |
|---|---|---|
| KMS key `vault-unseal` | Cloud KMS (persistent stack) | Permanent; cannot be deleted, only its versions scheduled for destruction |
| Root token | **Nowhere.** Used once by `bootstrap-secrets.sh` (through `kubectl exec` stdin), then revoked | Seconds |
| Bootstrap token (policy `vault-bootstrap`, orphan, 30 min, not renewable) | Secret `vault/vault-bootstrap` key `token` | Until the config Job uses it and deletes the Secret, or 30 minutes |
| Recovery keys (3, threshold 2) | Secret Manager `vault-recovery-keys` (JSON: `recovery_keys_b64`, `recovery_keys_hex`, shares, threshold) | As long as this Vault lives (until the next `make down`) |
| App secrets | Vault KV (`kv/<ns>/...`), copied by VSO into namespace Secrets | Until the next `make down` (see follow-ups) |

`vault-recovery-keys` is not in Terraform (CI's apply identity cannot write Secret Manager). `bootstrap-secrets.sh` creates it on first use (needs `roles/secretmanager.admin` the first time, then version add). No value reaches the terminal, argv, env, logs or Git: the init output lives only in a 0600 file in the script's private temp dir (deleted right after use). Inside `vault-0` the root token sits in the CLI token helper file `$HOME/.vault-token` for the few commands that need it and is removed by a trap.

The bootstrap token's policy is defined once, in `VAULT_BOOTSTRAP_POLICY` in `scripts/bootstrap-secrets.sh` (audit devices, mounts, auth methods, ACL policies, `auth/kubernetes/*`, `kv/*`, `auth/token/revoke-self`). Add paths there if the config Job needs more.

## Init flow (every `make up`)

1. `bootstrap-secrets.sh` checks whether Argo CD deploys the `vault` Application. If the root app `argocd-root` does not list it, the script prints a notice and skips (not a failure). If it is listed but not created yet (earlier sync waves), it waits up to `VAULT_APP_TIMEOUT` (900 s) and then **fails** ("re-run the script"): an uninitialized Vault must not be left for someone else to initialize.
2. It waits up to `VAULT_POD_TIMEOUT` (600 s) for `vault-0` to be Running with its API answering (`vault status` exit code 0 = unsealed, 2 = sealed or uninitialized, 1 = error).
3. **Not initialized:** it creates `vault-recovery-keys` if missing (before init, so a permission problem cannot lose the output), runs `vault operator init -recovery-shares=3 -recovery-threshold=2`, adds a new version of `vault-recovery-keys`, waits for KMS auto-unseal, then sends the root token on stdin to a short script in `vault-0` that writes policy `vault-bootstrap`, creates an orphan token with it (orphan, so revoking root does not revoke it) and revokes the root token. The bootstrap token goes into Secret `vault/vault-bootstrap` with `kubectl create` (not `apply`, which would copy it into the last-applied annotation).
4. **Already initialized:** never re-initialized. The script then requires that
   - Vault unseals within `VAULT_UNSEAL_TIMEOUT` (120 s), else it fails (KMS problem, see Troubleshooting);
   - the latest `vault-recovery-keys` version is newer than PVC `data-vault-0` (the pod if there is no PVC). Otherwise someone else may have initialized this Vault (front-running) and holds its keys: the script fails and asks for a rebuild;
   - Vault is configured (`kubernetes/` visible in the unauthenticated `sys/internal/ui/mounts`, the same test the config Job uses), or `vault/vault-bootstrap` still exists (Job pending). Initialized, unconfigured and no Secret: it fails with the recovery options below. It does not recreate the Secret: the root token is not stored.
5. The config Job (`idp-gitops`) waits for `vault/vault-bootstrap`, enables KV, Kubernetes auth, policies and the demo (`kv/vault-demo/hello`), revokes its token and deletes the Secret.
6. `verify.sh` step 8 checks `vault-0`, `Initialized true` / `Sealed false`, and that VSO synced Secret `vault-demo/hello` (key `message`; the value is never printed).

**Rebuilds:** Vault's data dies with the cluster, so each `make up` initializes a brand-new Vault and adds a new version of `vault-recovery-keys`. Older versions belong to a destroyed Vault and are useless (disable them whenever convenient: `gcloud secrets versions disable <n> --secret=vault-recovery-keys`). Only `latest` matters. KV data written by hand is lost too: anything that must survive belongs in Git (config Job) or in the portal flow that writes it again.

## Getting an admin token later

No root token exists after the init. To get one, two of the three recovery keys are needed (`generate-root` with an auto-unseal Vault takes recovery keys):

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

Use the token for the task at hand, then revoke it (`vault token revoke -self`). Cancel an unfinished attempt with `vault operator generate-root -cancel`. Prefer a scoped admin policy over root for anything regular. To finish a failed bootstrap by hand, use that token to write the policy and create the bootstrap token as `VAULT_BOOTSTRAP_POLICY` / `VAULT_IN_POD` in the script do, then `kubectl -n vault create secret generic vault-bootstrap --from-file=token=<file>`; a rebuild is usually simpler.

## Rebuild Vault

Human step; Argo CD recreates both objects, and the next script run initializes the fresh Vault:

```sh
kubectl -n vault delete pvc data-vault-0 --wait=false
kubectl -n vault delete pod vault-0
./scripts/bootstrap-secrets.sh
```

On a lab rebuild, `make down` / `make up` does the same.

## Troubleshooting

- **Initialized but sealed** (`bootstrap-secrets.sh` or `verify.sh` fails with the KMS hint): `kubectl -n vault logs vault-0`. `PermissionDenied` on the key means the GSA grants or the Workload Identity binding are missing (was `envs/persistent` applied?), or the KSA lacks the `iam.gke.io/gcp-service-account` annotation. Wrong project/location/ring/key in the seal stanza shows as `NotFound`.
- **Recovery keys older than Vault's disk** ("may have been initialized by someone else"): do not use this Vault; rebuild it.
- **Init output lost** (init errored but Vault is initialized, or storing `vault-recovery-keys` failed, or the run was interrupted): this Vault cannot be recovered. Rebuild it.
- **Bootstrap token step failed** (login, policy write, token creation or root revocation): the recovery keys are already in Secret Manager. Get a token with `generate-root` and finish by hand, or rebuild. If only the root revocation failed, the root token is still valid but held by nobody; rebuild to be safe.
- **Initialized, not configured, `vault/vault-bootstrap` gone** (the 30-minute token expired before the Job ran, or a run failed after init): `generate-root` and finish by hand, or rebuild.
- **The config Job never finishes:** it waits for `vault/vault-bootstrap`; re-run `./scripts/bootstrap-secrets.sh` once `vault-0` is Running.

## Security notes

- **Who can use the KMS key:** anything that can obtain tokens for KSA `vault/vault` (create pods with that service account, or create its tokens, in namespace `vault`) can encrypt and decrypt with `vault-unseal`, and so unwrap Vault's root key from a copy of its storage. Keep RBAC in namespace `vault` tight.
- **Who can destroy or re-grant the key:** the CI apply service account holds `roles/cloudkms.admin` and `roles/resourcemanager.projectIamAdmin` at project level, so a workflow on `main` can schedule key versions for destruction or grant the key to anyone. `prevent_destroy` only stops Terraform from planning a destroy; it does not protect the key from other API calls. Recommended (not implemented): org policy constraint `constraints/cloudkms.minimumDestroyScheduledDuration` (for example 30 days, to have time to notice and restore) and, where available, `constraints/cloudkms.disableBeforeDestroy`. A destroyed key version makes a Vault sealed with it unrecoverable; for this lab Vault is rebuilt anyway, but the same key would protect any future persistent Vault.


## License

Vault 1.15 and later (community edition included) is under the Business Source License 1.1 (BUSL), not an OSI open-source license. Running it to protect our own lab platform is permitted; offering Vault itself as a competing hosted service is not. OpenBao (the MPL-2.0 fork, same API and `gcpckms` seal) is the drop-in alternative if that ever matters.

## Follow-ups (not in Phase 1b)

- **Raft snapshots to GCS** on a schedule (a CronJob with a snapshot-only policy and a bucket-scoped GSA), so KV data can survive a rebuild via `vault operator raft snapshot restore`.
- **TLS on the Vault listener** with a cert-manager Certificate (in-cluster CA); until then the listener is plain HTTP, reachable in-cluster only.
- **Cloud SQL is out of scope**: databases stay in-cluster (CloudNativePG) with Vault dynamic credentials (section 10.4).
