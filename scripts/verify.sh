#!/usr/bin/env bash
# Post-build checks, run by `make up` and by hand (`make verify`). Deterministic:
# exits non-zero on the first failing check after a polling timeout.
# Checks: (1) every Argo CD Application is Synced and Healthy;
#         (2) the Tailscale operator is available; (3) cert-manager is available;
#         (4) echo app Certificate Ready and HTTPS 200 (once the app exists).
set -euo pipefail

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
DOMAIN="${DOMAIN:-ithaca-idp.com}"
TIMEOUT="${VERIFY_TIMEOUT:-900}" # seconds to wait for the sync waves to settle
INTERVAL=10

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP  %s\n' "$*"; }

# Idempotent: makes sure kubectl points at this cluster (through the DNS endpoint).
gcloud container clusters get-credentials "$CLUSTER" --dns-endpoint --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 \
  || fail "could not get credentials for $CLUSTER (needs gcloud with --dns-endpoint support)"

apps_table() {
  kubectl get applications.argoproj.io -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null
}

# --- 1. Argo CD applications -------------------------------------------------
deadline=$((SECONDS + TIMEOUT))
while :; do
  table="$(apps_table || true)"
  total="$(awk -F'\t' 'NF>=3' <<<"$table" | wc -l | tr -d ' ')"
  bad="$(awk -F'\t' 'NF>=3 && ($2!="Synced" || $3!="Healthy")' <<<"$table")"
  if [ "$total" -gt 0 ] && [ -z "$bad" ]; then
    pass "all $total Argo CD applications are Synced and Healthy"
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    printf '%s\n' "$table" >&2
    fail "Argo CD applications not all Synced/Healthy after ${TIMEOUT}s (found $total)"
  fi
  sleep "$INTERVAL"
done

# --- 2. Tailscale operator (wave 2) ------------------------------------------
# Needs Secret tailscale/operator-oauth from scripts/bootstrap-secrets.sh; without it the Pod never starts.
kubectl -n tailscale wait --for=condition=Available deployment/operator --timeout=180s >/dev/null \
  || fail "deployment operator in tailscale is not Available (Secret tailscale/operator-oauth missing? run ./scripts/bootstrap-secrets.sh)"
pass "Tailscale operator deployment is Available"

# --- 3. cert-manager ---------------------------------------------------------
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl -n cert-manager wait --for=condition=Available "deployment/$d" --timeout=120s >/dev/null \
    || fail "deployment $d in cert-manager is not Available"
done
pass "cert-manager deployments are Available"

# --- 4. echo app (added in wave 3) -------------------------------------------
if kubectl get applications.argoproj.io echo -n argocd >/dev/null 2>&1; then
  kubectl -n echo wait --for=condition=Ready certificate --all --timeout=300s >/dev/null \
    || fail "echo Certificate is not Ready"
  pass "echo Certificate is Ready"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://echo.apps.${DOMAIN}")"
  [ "$code" = "200" ] || fail "https://echo.apps.${DOMAIN} returned HTTP $code"
  pass "https://echo.apps.${DOMAIN} returned 200"
else
  skip "echo app not deployed yet (wave 3)"
fi

echo "verify.sh: all checks passed"
