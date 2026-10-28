# vault-unseal

Cloud KMS auto-unseal for the self-hosted Vault, in the persistent stack. See `docs/vault.md`.

- Key `vault-unseal` in the existing key ring from `modules/kms` (same location): `ENCRYPT_DECRYPT`, software protection, 90-day rotation, `prevent_destroy`. Key versions can only be scheduled for destruction, never deleted, and a destroyed key makes a Vault sealed with it unrecoverable.
- Google service account `vault` with no project roles. On the key only: `roles/cloudkms.cryptoKeyEncrypterDecrypter` (wrap/unwrap) and `roles/cloudkms.viewer` (the seal reads key metadata, `cloudkms.cryptoKeys.get`).
- Workload Identity binding for the KSA `vault/vault` (the Helm release `vault` in `idp-gitops`).
- No secrets here: `scripts/bootstrap-secrets.sh` runs `vault operator init`, stores only the recovery keys in Secret Manager `vault-recovery-keys` (CI cannot write secrets) and revokes the root token after minting a short-lived bootstrap token.

In `idp-gitops`, annotate the server KSA with `iam.gke.io/gcp-service-account: <vault_sa>` and set the `gcpckms` seal from the `vault_kms_*` outputs of `envs/persistent`.
