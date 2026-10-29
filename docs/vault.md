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
| Proof admin token (policy `vault-proof`, orphan, TTL = worst-case run, at least 45 min) | A 0600 temp file of `scripts/vault-proof.sh` while it runs | Revoked by the script's cleanup; at most its TTL if the script is killed |
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

## Proving per-namespace isolation

`verify.sh` only checks that a TeamNamespace gets its `vault-reader` ServiceAccount and VaultAuth. `scripts/vault-proof.sh` proves the rest on a running cluster: a namespace reads its own `kv/<ns>/` through VSO, cannot read another namespace's path (Vault answers 403), the portal's role `portal-secrets` is write-only, and deleting a TeamNamespace purges its KV data (design: idp-gitops `workloads/vault/README.md`, "Per-namespace access" and "Portal Secrets"). Human-run only, from a laptop with `gcloud`, `kubectl` (pointed at the cluster, allowed to create a token for `idp-system/portal-api`), `jq` and `sha256sum` or `shasum`; your gcloud user needs `secretmanager.secretAccessor` on `vault-recovery-keys`. It takes about 3 to 10 minutes.

```sh
./scripts/vault-proof.sh             # run the proof
./scripts/vault-proof.sh --cleanup   # remove leftovers of an interrupted run
```

What it creates and touches (all removed again on exit, also on failure or Ctrl-C):

- a `generate-root` attempt with the recovery keys (2 of 3). The root token is decoded on the laptop with shell builtins, sent on `kubectl exec -i` stdin to one exec in `vault-0` that writes policy `vault-proof` and creates an **orphan admin token** (not renewable, only `kv/vproof-a/` and `kv/vproof-b/`, read of role `portal-secrets`, delete of its own policy, plus the default policy so it can revoke itself after that), then revokes the root token. The TTL covers the worst-case run (all waits plus 15 minutes, at least 45 minutes, printed); the cleanup revokes it as soon as it is done. It refuses to overwrite a `vault-proof` policy with different content, and deletes the policy in the cleanup.
- TeamNamespaces `vproof-a` and `vproof-b` (label `idp.ithaca-idp.com/vault-proof=true`, owner `verify@example.com`), the namespaces and objects the operator creates for them, VaultStaticSecrets and the Secrets VSO writes in them, and `kv/vproof-a/hello`, `kv/vproof-b/hello` (random values).
- P7 (only if role `portal-secrets` exists): a 10-minute ServiceAccount token for `idp-system/portal-api` (audience `vault`), a Vault login with it, one key `kv/vproof-a/p7-<random>` (deleted right away) and write attempts to `kv/vault-demo/` and `kv/idp-system/` that must be denied (removed again, or listed for you, if they were not).
- It refuses to start if `vproof-a` or `vproof-b` already exists (only `--cleanup` removes ones carrying its label; anything else is never touched) or if a `generate-root` attempt is in progress.

Secrets (recovery keys, OTP, root, admin and portal tokens, test values) only live in 0600 files in a private temp dir and in pipes, never in argv, env or output; values are compared by sha256.

**If the root token cannot be revoked** (minting the admin token failed and the cleanup's revoke failed too), the script does NOT delete it: it prints a loud warning with the path of the 0600 file and the exact command that revokes it with the token on stdin (`kubectl -n vault exec -i vault-0 -- sh -c '... vault token revoke -self ...' < <file>`). Run it, then delete the file; if it fails, rebuild Vault.

**If the admin token expired or stopped working** before the cleanup, the cleanup lists every KV key this run wrote and could not remove, each with `vault kv metadata delete -mount=kv <key>` (needs an admin token, see "Getting an admin token later"), and reports policy `vault-proof` as left over. The operator also purges `kv/vproof-a/` and `kv/vproof-b/` whenever a TeamNamespace of that name is created or deleted.

Expected output (abridged):

```
==> 1. preflight ... PASS  preflight
==> 2. short-lived admin token ... PASS  admin token: orphan, policy vault-proof, TTL 2700s; root token revoked
==> 3. TeamNamespaces vproof-a and vproof-b ... PASS  ... VaultReady=True, ServiceAccount and VaultAuth vault-reader
==> 4. write kv/vproof-a/hello and kv/vproof-b/hello ... PASS
==> 5. positive
    PASS  P1 vproof-a reads its own secret: Secret vproof-a/hello key message matches kv/vproof-a/hello by sha256
    PASS  P2 vproof-b reads its own secret: ...
==> 6. negative
    PASS  P3 vproof-a cannot read kv/vproof-b/hello: Secret vproof-a/hello-b absent after 60s, Vault answered 403 (VSO Warning reason: <reason>)
    PASS  P4 vproof-b cannot read kv/vproof-a/hello: ...
==> 7. P7: Vault role portal-secrets (portal Secrets page) is write-only
    read kv/data/vproof-a/hello: denied (want denied)
    write kv/data/vproof-a/p7-...: allowed (want allowed)
    write kv/data/vault-demo/vproof-p7-...: denied (want denied)
    write kv/data/idp-system/vproof-p7-...: denied (want denied)
    list kv/metadata/: denied (want denied)
    read kv/metadata/vproof-a/hello: denied (want denied)
    list kv/metadata/vproof-a/: denied (want denied)
    PASS  P7 role portal-secrets is write-only: ...
    (or: SKIP  P7 role portal-secrets does not exist yet ...)
==> 8. purge
    PASS  P5 deleting vproof-a purged kv/vproof-a/ and left kv/vproof-b/hello intact
    PASS  P6 deleting vproof-b purged kv/vproof-b/; kv/vproof-a/ and kv/vproof-b/ are both gone
==> cleanup
    deleted policy vault-proof
    revoked the admin token
===== vault-proof.sh summary (took ...) =====
RESULT: all proofs passed
```

The metadata checks of P7 (read/list on `kv/metadata/<ns>/` denied) expect the tightened `portal-secrets` policy; set `PROOF_P7_METADATA=skip` to leave them out against a policy that still grants them. Exit code 0 only if every line is PASS or SKIP. What a FAIL means:

| FAIL | Meaning |
|---|---|
| `setup: ... leftover of an earlier run` | An interrupted run left `vproof-*`: run `--cleanup`, then retry. |
| `setup: ... not created by this script` | Someone else owns that name; the script will not touch it. |
| `setup: ... generate-root attempt is already in progress` | Another admin, or a killed run. Cancel it (command printed) only if it is yours. |
| `setup: policy vault-proof already exists ... did not write` | Someone else uses that policy name; it is not touched. Inspect it before anything else. |
| `setup: submitting recovery key ...` / `could not decode` / `admin token step` | `vault-recovery-keys` `latest` does not belong to this Vault, or Vault refused. A root token that was generated but not revoked is revoked by the cleanup; if that fails, see "If the root token cannot be revoked". |
| `setup: TeamNamespace ... Ready` / `VaultReady` | Operator problem (`kubectl -n idp-system logs deploy/idp-operator`); often the initial purge cannot log in to Vault. |
| `P1`/`P2` did not appear | VSO cannot log in with role `ns-reader` or read its own path: check the VaultStaticSecret events, the `ns-reader` policy/role (config Job), the VaultConnection. |
| `P1`/`P2` holds a different value | VSO synced something other than what was written: stale Secret or wrong path. |
| `P3`/`P4` ISOLATION BROKEN | **Security bug**: a namespace read another namespace's secret. Check the `ns-reader` policy template and the role's bound namespaces before anything else. |
| `P3`/`P4` inconclusive | The Secret stayed absent, but there is no evidence that Vault denied it: no Warning event, a Warning without 403/permission denied (VSO not reconciled, Vault unreachable), or the positive proof in the same namespace failed. Not a proof either way. |
| `P7 ... not write-only as designed; <op> <path> is allowed` | **Security bug** in policy `portal-secrets` (`is error` means the attempt failed for another reason, see `kubectl -n vault logs vault-0`). |
| `P7 could not get a token` / `log in` | No ServiceAccount `idp-system/portal-api`, no right to create its token, or role `portal-secrets` bound differently. |
| `P5`/`P6` not removed | The operator's purge finalizer is stuck (`VaultPurgePending`, `idp-operator-purge` login or policy). |
| `P5`/`P6` `kv/<ns>/ is present` | The purge did not delete the data; `kv/vproof-b/ changed` means it deleted too much. `is error` usually means the admin token stopped working. |
| `cleanup: ...` | Something is left behind; follow the printed commands and run `--cleanup`. |

What it cannot prove: that tenant admins cannot create a `vault-reader` ServiceAccount token elsewhere (RBAC, see the idp-gitops README), that portal-api only writes where the signed-in user may (decided in portal-api, not Vault), anything about Vault paths other than those tested, and behaviour under a different VSO or Vault version than the one running.

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
