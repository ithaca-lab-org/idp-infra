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
