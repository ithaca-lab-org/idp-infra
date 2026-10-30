#!/usr/bin/env bash
# Run by `make up` after `terraform apply` and before verify.sh. Copies the bootstrap
# secrets that cannot live in Git from Google Secret Manager into the fresh cluster:
#   Secret Manager tailscale-oauth-client-id / -secret  ->  Secret tailscale/operator-oauth
#                                                           (keys client_id, client_secret)
# The Tailscale operator (idp-gitops, wave 2) mounts that Secret by name; its Pod waits in
# ContainerCreating until it exists. Idempotent: safe to re-run, and re-running after a
# rotation updates the Secret. Never prints secret values. See docs/tailscale.md.
# Identity secrets (lldap, Keycloak admin, Keycloak DB) are generated into Secret Manager on
# first run (random, never printed) and copied into the identity namespace. See docs/identity.md.
# The optional Resend API key is copied to idp-system/notifier-resend when it has a version
# (docs/order-events.md).
# Vault (optional, only when idp-gitops deploys the `vault` Application): waits for vault-0 and,
# if Vault is not initialized yet, runs `vault operator init` once, stores only the recovery keys
# (new version of vault-recovery-keys in Secret Manager), swaps the root token for a 30-minute
# bootstrap token in Secret vault/vault-bootstrap (key token) and revokes the root token. Already
# initialized: never re-initialized, only checked. See docs/vault.md.
# Replaced by External Secrets in a later phase (ADR 0005).
set -euo pipefail
set +x # never trace: the values below must not reach the terminal or CI logs

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
TS_NAMESPACE="${TS_NAMESPACE:-tailscale}"
TS_K8S_SECRET="operator-oauth" # fixed by the tailscale-operator chart (1.102.x)
SM_CLIENT_ID="${TS_OAUTH_CLIENT_ID_SECRET:-tailscale-oauth-client-id}"
SM_CLIENT_SECRET="${TS_OAUTH_CLIENT_SECRET_SECRET:-tailscale-oauth-client-secret}"

die() { printf 'bootstrap-secrets: %s\n' "$*" >&2; exit 1; }

for tool in gcloud kubectl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

# Values only ever live in this private temp dir and in shell variables, never in argv
# (so not in `ps`) and never on stdout.
umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-secrets.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# read_secret <secret-manager-name> <output-file>
read_secret() {
  local name="$1" out="$2" value
  if ! value="$(gcloud secrets versions access latest --secret="$name" --project="$PROJECT" 2>"$tmp/err")"; then
    if grep -q 'NOT_FOUND' "$tmp/err"; then
      die "secret '$name' (or an enabled version of it) not found in project $PROJECT. Create it first, see docs/tailscale.md."
    elif grep -q 'PERMISSION_DENIED' "$tmp/err"; then
      die "no access to secret '$name' in project $PROJECT. You need roles/secretmanager.secretAccessor (check 'gcloud auth list')."
    fi
    die "could not read secret '$name' from project $PROJECT: $(head -n 1 "$tmp/err")"
  fi
  [ -n "$value" ] || die "secret '$name' in project $PROJECT is empty"
  printf '%s' "$value" >"$out"
}

read_secret "$SM_CLIENT_ID" "$tmp/client_id"
read_secret "$SM_CLIENT_SECRET" "$tmp/client_secret"
echo "bootstrap-secrets: read $SM_CLIENT_ID and $SM_CLIENT_SECRET from Secret Manager"

# Idempotent: makes sure kubectl points at this cluster (through the DNS endpoint).
gcloud container clusters get-credentials "$CLUSTER" --dns-endpoint --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 \
  || die "could not get credentials for $CLUSTER (needs gcloud with --dns-endpoint support)"

# Argo CD also creates this namespace (CreateNamespace=true); whichever runs first wins.
# No istio.io/dataplane-mode label here: the operator and its proxies stay outside the ambient mesh.
kubectl create namespace "$TS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create namespace $TS_NAMESPACE"

# The dry-run output contains the (base64) values, so it only ever goes through the pipe.
kubectl -n "$TS_NAMESPACE" create secret generic "$TS_K8S_SECRET" \
  --from-file=client_id="$tmp/client_id" \
  --from-file=client_secret="$tmp/client_secret" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create or update Secret $TS_NAMESPACE/$TS_K8S_SECRET"

echo "bootstrap-secrets ok: Secret $TS_NAMESPACE/$TS_K8S_SECRET is in place (values not shown)"

# --- identity namespace (lldap, Keycloak, Keycloak Postgres) ---------------------------------
ID_NAMESPACE="${ID_NAMESPACE:-identity}"

# ensure_secret <secret-manager-name>: creates the secret with a random 64-char hex value if it
# has no enabled version yet. The value goes through a pipe only, never argv, never stdout.
ensure_secret() {
  local name="$1"
  if gcloud secrets versions access latest --secret="$name" --project="$PROJECT" >/dev/null 2>"$tmp/err"; then
    return 0
  fi
  grep -q 'NOT_FOUND' "$tmp/err" || die "cannot read secret '$name': $(head -n 1 "$tmp/err")"
  if ! gcloud secrets describe "$name" --project="$PROJECT" >/dev/null 2>&1; then
    gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT" >/dev/null 2>"$tmp/err" \
      || die "could not create secret '$name': $(head -n 1 "$tmp/err")"
  fi
  openssl rand -hex 32 | gcloud secrets versions add "$name" --data-file=- --project="$PROJECT" >/dev/null 2>"$tmp/err" \
    || die "could not add a version to secret '$name': $(head -n 1 "$tmp/err")"
  echo "bootstrap-secrets: generated $name in Secret Manager"
}

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"
for s in lldap-admin-password lldap-jwt-secret lldap-key-seed keycloak-admin-password keycloak-db-password portal-session-key portal-mongo-root-password portal-mongo-password lldap-seed-users-password; do
  ensure_secret "$s"
  read_secret "$s" "$tmp/$s"
done

kubectl create namespace "$ID_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create namespace $ID_NAMESPACE"

# apply_secret <k8s-name> <key>=<file>...  (dry-run output holds base64 values: pipe only)
apply_secret() {
  local name="$1"; shift
  local args=() kv
  for kv in "$@"; do args+=(--from-file="${kv%%=*}=${kv#*=}"); done
  kubectl -n "$ID_NAMESPACE" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || die "could not create or update Secret $ID_NAMESPACE/$name"
}

apply_secret lldap \
  "admin-password=$tmp/lldap-admin-password" \
  "jwt-secret=$tmp/lldap-jwt-secret" \
  "key-seed=$tmp/lldap-key-seed"

# Optional: the tailnet domain (for example tail1234.ts.net) stays out of Git. If the Secret Manager
# secret "tailnet-domain" exists, Keycloak gets its admin console URL (KC_HOSTNAME_ADMIN) from it.
admin_url=()
if tailnet="$(gcloud secrets versions access latest --secret=tailnet-domain --project="$PROJECT" 2>"$tmp/err")"; then
  tailnet="$(printf '%s' "$tailnet" | tr -d '[:space:]')"
  [[ "$tailnet" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$ ]] || die "secret tailnet-domain is not a *.ts.net name"
  printf 'https://keycloak-admin.%s' "$tailnet" >"$tmp/keycloak-admin-url"
  admin_url=("admin-url=$tmp/keycloak-admin-url")
elif grep -q 'NOT_FOUND' "$tmp/err"; then
  echo "bootstrap-secrets: no tailnet-domain secret; Keycloak admin console is not reachable over Tailscale (docs/identity.md)"
else
  die "cannot read secret 'tailnet-domain': $(head -n 1 "$tmp/err")"
fi
apply_secret keycloak-admin "password=$tmp/keycloak-admin-password" ${admin_url[@]+"${admin_url[@]}"}
apply_secret keycloak-db "password=$tmp/keycloak-db-password"
# One shared password for the seeded dev users (idp-gitops workloads/identity/lldap-seed.yaml). Generated at
# random; set your own with: printf %s "<password>" | gcloud secrets versions add lldap-seed-users-password --data-file=-
apply_secret lldap-seed-users "password=$tmp/lldap-seed-users-password"

echo "bootstrap-secrets ok: Secrets $ID_NAMESPACE/{lldap,keycloak-admin,keycloak-db,lldap-seed-users} are in place (values not shown)"

# --- idp-system namespace (portal) ---------------------------------------------
# The portal decodes SESSION_KEY as base64; the 64-char hex value is valid base64 text and
# decodes to 48 random bytes, so the same generator is reused.
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-idp-system}"
kubectl create namespace "$PORTAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create namespace $PORTAL_NAMESPACE"
kubectl -n "$PORTAL_NAMESPACE" create secret generic portal-session \
  --from-file=session-key="$tmp/portal-session-key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create or update Secret $PORTAL_NAMESPACE/portal-session"
echo "bootstrap-secrets ok: Secret $PORTAL_NAMESPACE/portal-session is in place (value not shown)"

# MongoDB for the portal's orders: the root password is only used to initialise the database and
# to create the portal's own user (readWrite on the idp database only), whose password the API uses.
kubectl -n "$PORTAL_NAMESPACE" create secret generic portal-mongo \
  --from-file=root-password="$tmp/portal-mongo-root-password" \
  --from-file=app-password="$tmp/portal-mongo-password" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create or update Secret $PORTAL_NAMESPACE/portal-mongo"
echo "bootstrap-secrets ok: Secret $PORTAL_NAMESPACE/portal-mongo is in place (values not shown)"

# Optional: the notifier's Resend API key. A human creates the Secret Manager
# secret and adds the version (docs/order-events.md); Terraform does not manage it. Until then sending is
# off (NOTIFIER_SEND_EMAIL unset) and the notifier mounts the Secret with optional: true, so a
# missing secret, or one without a version, is skipped here instead of failing `make up`.
# Never generated: the value comes from Resend.
SM_RESEND="${RESEND_API_KEY_SECRET:-resend-api-key}"
if gcloud secrets versions access latest --secret="$SM_RESEND" --project="$PROJECT" >"$tmp/resend-api-key" 2>"$tmp/err"; then
  [ -s "$tmp/resend-api-key" ] || die "secret '$SM_RESEND' in project $PROJECT is empty"
  kubectl -n "$PORTAL_NAMESPACE" create secret generic notifier-resend \
    --from-file=api-key="$tmp/resend-api-key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || die "could not create or update Secret $PORTAL_NAMESPACE/notifier-resend"
  echo "bootstrap-secrets ok: Secret $PORTAL_NAMESPACE/notifier-resend is in place (value not shown)"
elif grep -q -E 'NOT_FOUND|FAILED_PRECONDITION' "$tmp/err"; then
  # NOT_FOUND: no secret or no version yet. FAILED_PRECONDITION: the latest version is disabled.
  echo "bootstrap-secrets: no enabled version of $SM_RESEND; skipping $PORTAL_NAMESPACE/notifier-resend (email sending stays off, docs/order-events.md)"
  # a revoked or deleted key must not linger in the cluster
  kubectl -n "$PORTAL_NAMESPACE" delete secret notifier-resend --ignore-not-found >/dev/null 2>&1 || true
else
  die "cannot read secret '$SM_RESEND': $(head -n 1 "$tmp/err")"
fi

# --- vault (optional): one-time init per cluster -------------------------------------------
# Vault's Raft disk dies with the cluster, so every `make up` brings up an empty, uninitialized
# Vault. This section initializes it once and then:
#   1. stores ONLY the recovery keys (3 shares, threshold 2; the Cloud KMS seal unseals Vault by
#      itself, so there are no unseal keys) as a NEW version of Secret Manager vault-recovery-keys
#      (older versions belong to a destroyed Vault and are useless);
#   2. uses the root token once, through `kubectl exec -i` STDIN only, to write policy
#      vault-bootstrap, mint an orphan token with that policy (30 min, not renewable) and revoke
#      the root token;
#   3. hands the orphan token to the idp-gitops config Job as Secret vault/vault-bootstrap (key token).
# The root token is never stored. Init output only lives in a 0600 file in this script's private
# temp dir and in pipes: never in argv, env, stdout or stderr. An already initialized Vault is never
# re-initialized, but it must have been initialized by this script (recovery keys newer than its
# disk), otherwise someone else may hold its keys. See docs/vault.md.
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_PVC="data-vault-0"
VAULT_APP="vault"
VAULT_K8S_SECRET="vault-bootstrap"
ROOT_APP="${ROOT_APP:-argocd-root}"
SM_VAULT_RECOVERY="vault-recovery-keys"
VAULT_APP_TIMEOUT="${VAULT_APP_TIMEOUT:-900}"       # Argo CD creates child Applications wave by wave
VAULT_POD_TIMEOUT="${VAULT_POD_TIMEOUT:-600}"       # vault-0 Running and its API answering
VAULT_UNSEAL_TIMEOUT="${VAULT_UNSEAL_TIMEOUT:-120}" # KMS auto-unseal normally takes seconds
VAULT_POLL="${VAULT_POLL:-10}"

# What the config Job's bootstrap token may do. The ONLY copy of this list (docs/vault.md points here).
VAULT_BOOTSTRAP_POLICY='path "sys/audit/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/audit" { capabilities = ["read", "list"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/auth" { capabilities = ["read", "list"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/kubernetes/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "kv/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/token/revoke-self" { capabilities = ["update"] }'

# Runs inside vault-0 (`sh -c`; the script text holds no secret). STDIN: the root token on the
# first line, then the policy. The CLI's token helper keeps the root token in $HOME/.vault-token for
# these few commands only; the trap removes it. STDOUT: only the orphan token JSON.
# Exit codes: 10 login, 11 policy write, 12 token create, 13 root revoke.
VAULT_IN_POD='set -eu
umask 077
cleanup() { rm -f "$HOME/.vault-token"; }
trap cleanup EXIT
trap "exit 1" INT TERM HUP
IFS= read -r t || exit 10
printf "%s" "$t" | vault login -no-print - >/dev/null || exit 10
t=""
vault policy write vault-bootstrap - >/dev/null || exit 11
vault token create -orphan -no-default-policy -policy=vault-bootstrap -ttl=30m -renewable=false -format=json || exit 12
vault token revoke -self >/dev/null || exit 13'

vault_app_exists() { kubectl -n argocd get applications.argoproj.io "$VAULT_APP" >/dev/null 2>&1; }

# Is the vault Application in the root app's desired state? Right after `terraform apply` Argo CD
# has not reached Vault's sync wave yet, so the Application can be planned but not created.
# Prints yes, no or unknown (root app not reconciled yet).
vault_app_planned() {
  local res
  res="$(kubectl -n argocd get applications.argoproj.io "$ROOT_APP" \
    -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -z "$res" ]; then
    echo unknown
  elif printf '%s\n' "$res" | grep -qx "Application/$VAULT_APP"; then
    echo yes
  else
    echo no
  fi
}

# vault_status: `vault status` exits 0 when unsealed, 2 when sealed (which includes "not
# initialized") and 1 on errors (API not listening yet). Sets VAULT_RC, VAULT_INIT and VAULT_SEALED
# ("true"/"false", empty when unknown). The status output contains no secrets.
vault_status() {
  local out
  VAULT_INIT=""
  VAULT_SEALED=""
  if out="$(kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- vault status -format=json 2>"$tmp/err")"; then
    VAULT_RC=0
  else
    VAULT_RC=$?
  fi
  case "$VAULT_RC" in 0 | 2) ;; *) return 0 ;; esac
  VAULT_INIT="$(printf '%s' "$out" | jq -r 'if (.initialized | type) == "boolean" then .initialized else "" end' 2>/dev/null || true)"
  VAULT_SEALED="$(printf '%s' "$out" | jq -r 'if (.sealed | type) == "boolean" then .sealed else "" end' 2>/dev/null || true)"
}

vault_kms_hint="auto-unseal with Cloud KMS is failing. Check: kubectl -n $VAULT_NAMESPACE logs $VAULT_POD (look for gcpckms or PermissionDenied), the KSA $VAULT_NAMESPACE/vault annotation iam.gke.io/gcp-service-account, and the vault GSA's grants on KMS key vault-unseal (envs/persistent applied?). See docs/vault.md."
vault_rebuild="Rebuild Vault: kubectl -n $VAULT_NAMESPACE delete pvc $VAULT_PVC --wait=false; kubectl -n $VAULT_NAMESPACE delete pod $VAULT_POD; then re-run ./scripts/bootstrap-secrets.sh (docs/vault.md, 'Rebuild Vault')."
vault_noadmin="No admin token can be obtained afterwards: Vault 2.0 requires a valid token for generate-root, so the recovery keys in $SM_VAULT_RECOVERY alone do not help (docs/vault.md, 'Admin access after the bootstrap'). $vault_rebuild"

wait_unsealed() {
  local deadline=$((SECONDS + VAULT_UNSEAL_TIMEOUT))
  while :; do
    vault_status
    [ "$VAULT_RC" = 0 ] && [ "$VAULT_SEALED" = false ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep "$VAULT_POLL"
  done
}

# RFC 3339 (optionally with fractional seconds, Z or +00:00) to epoch seconds; empty on error.
to_epoch() {
  jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601' 2>/dev/null || true
}

# Front-running guard: the latest recovery-keys version must be newer than Vault's disk (the PVC;
# the pod if there is none: pods are recreated on Spot preemption, PVCs are not). If not, this
# Vault was initialized by someone else, whose recovery keys and root token we do not have.
vault_keys_fresh() {
  local disk vtime d v
  disk="$(kubectl -n "$VAULT_NAMESPACE" get pvc "$VAULT_PVC" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  [ -n "$disk" ] || disk="$(kubectl -n "$VAULT_NAMESPACE" get pod "$VAULT_POD" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  vtime="$(gcloud secrets versions describe latest --secret="$SM_VAULT_RECOVERY" --project="$PROJECT" \
    --format='value(createTime)' 2>/dev/null || true)"
  d="$(to_epoch "$disk")"
  v="$(to_epoch "$vtime")"
  [ -n "$d" ] && [ -n "$v" ] && [ "$v" -gt "$d" ]
}

# Same detection as the config Job: once configured, the kubernetes/ auth mount is listed by the
# unauthenticated sys/internal/ui/mounts endpoint (the Job tunes it to listing-visibility=unauth).
vault_configured() {
  kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- vault read -format=json sys/internal/ui/mounts 2>/dev/null \
    | grep -q '"kubernetes/"'
}

# Create a Secret Manager secret without a version if it does not exist yet. Done BEFORE the init,
# so a missing permission cannot lose the init output.
ensure_secret_container() {
  local name="$1"
  if gcloud secrets describe "$name" --project="$PROJECT" >/dev/null 2>"$tmp/err"; then
    return 0
  fi
  grep -q 'NOT_FOUND' "$tmp/err" || die "cannot read secret '$name': $(head -n 1 "$tmp/err")"
  gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT" >/dev/null 2>"$tmp/err" \
    || die "could not create secret '$name': $(head -n 1 "$tmp/err")"
  echo "bootstrap-secrets: created secret $name in Secret Manager"
}

vault_deployed=""
if vault_app_exists; then
  vault_deployed=1
else
  deadline=$((SECONDS + VAULT_APP_TIMEOUT))
  while :; do
    planned="$(vault_app_planned)"
    if [ "$planned" = no ]; then
      break
    elif [ "$planned" = yes ] && vault_app_exists; then
      vault_deployed=1
      break
    fi
    # A skipped init leaves an uninitialized Vault for anyone to initialize: never skip silently.
    if [ "$SECONDS" -ge "$deadline" ]; then
      [ "$planned" = yes ] && die "Argo CD has not created the $VAULT_APP Application after ${VAULT_APP_TIMEOUT}s (earlier sync waves not Healthy?). Vault is NOT initialized: re-run ./scripts/bootstrap-secrets.sh once it exists."
      die "Argo CD has not reconciled $ROOT_APP after ${VAULT_APP_TIMEOUT}s, so it is unknown whether Vault is deployed. Re-run ./scripts/bootstrap-secrets.sh once Argo CD is up."
    fi
    if [ "$planned" = yes ]; then
      echo "bootstrap-secrets: waiting for Argo CD to create the $VAULT_APP Application (earlier sync waves first)"
    else
      echo "bootstrap-secrets: waiting for Argo CD to reconcile $ROOT_APP"
    fi
    sleep "$VAULT_POLL"
  done
fi

if [ -z "$vault_deployed" ]; then
  echo "bootstrap-secrets: notice: Argo CD Application $VAULT_APP is not deployed; skipping Vault init (docs/vault.md)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq not found on PATH (needed to read vault status and init output)"

echo "bootstrap-secrets: waiting up to ${VAULT_POD_TIMEOUT}s for pod $VAULT_NAMESPACE/$VAULT_POD"
deadline=$((SECONDS + VAULT_POD_TIMEOUT))
while :; do
  phase="$(kubectl -n "$VAULT_NAMESPACE" get pod "$VAULT_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" = Running ]; then
    vault_status
    [ -n "$VAULT_INIT" ] && [ -n "$VAULT_SEALED" ] && break
  fi
  [ "$SECONDS" -ge "$deadline" ] \
    && die "pod $VAULT_NAMESPACE/$VAULT_POD is not Running with its API answering after ${VAULT_POD_TIMEOUT}s (phase: ${phase:-none}; kubectl -n $VAULT_NAMESPACE describe pod $VAULT_POD; kubectl -n $VAULT_NAMESPACE logs $VAULT_POD)"
  sleep "$VAULT_POLL"
done

if [ "$VAULT_INIT" = true ]; then
  # Never re-initialize and never overwrite the stored keys or the K8s Secret.
  if [ "$VAULT_SEALED" = true ]; then
    echo "bootstrap-secrets: Vault is initialized but sealed; waiting up to ${VAULT_UNSEAL_TIMEOUT}s for KMS auto-unseal"
    wait_unsealed || die "Vault is initialized but still sealed after ${VAULT_UNSEAL_TIMEOUT}s: $vault_kms_hint"
  fi
  vault_keys_fresh || die "Vault is ALREADY INITIALIZED, but the latest $SM_VAULT_RECOVERY version in Secret Manager is not newer than Vault's disk: it may have been initialized by someone else, who would hold its root token and recovery keys. Do not use this Vault. $vault_rebuild"
  if vault_configured; then
    echo "bootstrap-secrets ok: Vault is initialized, unsealed and configured; nothing to do"
  elif kubectl -n "$VAULT_NAMESPACE" get secret "$VAULT_K8S_SECRET" >/dev/null 2>&1; then
    echo "bootstrap-secrets ok: Vault is initialized and unsealed; the config Job has not finished yet (Secret $VAULT_NAMESPACE/$VAULT_K8S_SECRET is present)"
  else
    die "Vault is initialized but not configured, and Secret $VAULT_NAMESPACE/$VAULT_K8S_SECRET is gone (a run that failed after init, or the 30-minute bootstrap token was never used). The root token is not stored anywhere. $vault_noadmin"
  fi
  exit 0
fi

ensure_secret_container "$SM_VAULT_RECOVERY"

echo "bootstrap-secrets: initializing Vault (3 recovery shares, threshold 2; output not shown)"
if ! kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- \
  vault operator init -format=json -recovery-shares=3 -recovery-threshold=2 >"$tmp/vault-init.json" 2>"$tmp/err"; then
  head -n 1 "$tmp/err" >"$tmp/init-err"
  # The exec can fail after Vault initialized (connection dropped): then the output is lost.
  vault_status
  [ "$VAULT_INIT" = true ] \
    && die "vault operator init reported an error ($(cat "$tmp/init-err")) but Vault IS initialized: its recovery keys and root token may be lost. $vault_rebuild"
  die "vault operator init failed: $(cat "$tmp/init-err")"
fi

vault_lost="Vault IS initialized, but its recovery keys were not stored and are lost. $vault_rebuild"
jq -j '.root_token // ""' "$tmp/vault-init.json" >"$tmp/vault-root-token" 2>/dev/null || die "could not parse the init output. $vault_lost"
[ -s "$tmp/vault-root-token" ] || die "the init output has no root token. $vault_lost"
jq '{recovery_keys_b64, recovery_keys_hex, recovery_keys_shares, recovery_keys_threshold}' \
  "$tmp/vault-init.json" >"$tmp/vault-recovery-keys" 2>/dev/null || die "could not parse the init output. $vault_lost"
jq -e '(.recovery_keys_b64 | length) == 3' "$tmp/vault-recovery-keys" >/dev/null 2>&1 \
  || die "the init output does not hold 3 recovery keys (is the gcpckms seal configured?). $vault_lost"
rm -f "$tmp/vault-init.json"

gcloud secrets versions add "$SM_VAULT_RECOVERY" --data-file="$tmp/vault-recovery-keys" --project="$PROJECT" >/dev/null 2>"$tmp/err" \
  || die "could not add a version to secret '$SM_VAULT_RECOVERY': $(head -n 1 "$tmp/err"). $vault_lost"
rm -f "$tmp/vault-recovery-keys"
echo "bootstrap-secrets: stored a new version of $SM_VAULT_RECOVERY in Secret Manager"

wait_unsealed || die "Vault was initialized but is still sealed after ${VAULT_UNSEAL_TIMEOUT}s: $vault_kms_hint Once it unseals: $vault_noadmin"

# Root token in on STDIN only (first line), policy after it; the orphan token JSON comes back on STDOUT.
{
  cat "$tmp/vault-root-token"
  printf '\n%s\n' "$VAULT_BOOTSTRAP_POLICY"
} | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- sh -c "$VAULT_IN_POD" >"$tmp/vault-orphan.json" 2>"$tmp/err" \
  && rc=0 || rc=$?
rm -f "$tmp/vault-root-token"
case "$rc" in
  0) ;;
  10) die "could not log in with the root token: $(head -n 1 "$tmp/err"). $vault_noadmin" ;;
  11) die "could not write policy vault-bootstrap: $(head -n 1 "$tmp/err"). The root token is still valid but stored nowhere. $vault_noadmin" ;;
  12) die "could not create the bootstrap token: $(head -n 1 "$tmp/err"). The root token is still valid but stored nowhere. $vault_noadmin" ;;
  13) die "could not revoke the root token: $(head -n 1 "$tmp/err"). It is still valid but stored nowhere; to be safe: $vault_rebuild" ;;
  *) die "the bootstrap step in $VAULT_POD failed (exit $rc): $(head -n 1 "$tmp/err"). The root token may still be valid but is stored nowhere. $vault_noadmin" ;;
esac
jq -j '.auth.client_token // ""' "$tmp/vault-orphan.json" >"$tmp/vault-bootstrap-token" 2>/dev/null || true
rm -f "$tmp/vault-orphan.json"
[ -s "$tmp/vault-bootstrap-token" ] || die "no bootstrap token in the token create output (the root token was revoked). $vault_noadmin"

# `kubectl create`, not `apply`: apply would copy the token into the last-applied annotation.
kubectl -n "$VAULT_NAMESPACE" delete secret "$VAULT_K8S_SECRET" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$VAULT_NAMESPACE" create secret generic "$VAULT_K8S_SECRET" \
  --from-file=token="$tmp/vault-bootstrap-token" >/dev/null 2>"$tmp/err" \
  || die "could not create Secret $VAULT_NAMESPACE/$VAULT_K8S_SECRET: $(head -n 1 "$tmp/err"). $vault_noadmin"
echo "bootstrap-secrets ok: Vault initialized and unsealed by Cloud KMS; root token revoked; Secret $VAULT_NAMESPACE/$VAULT_K8S_SECRET holds a 30-minute bootstrap token for the config Job (value not shown)"
