#!/usr/bin/env bash
# Post-build checks, run by `make up` and by hand (`make verify`). Deterministic:
# exits non-zero on the first failing check after a polling timeout.
# Checks: (1) every Argo CD Application is Synced and Healthy;
#         (2) the Tailscale operator is available; (3) cert-manager is available;
#         (4) echo app: wildcard Certificate Ready, DNS -> reserved IP, HTTPS 200 (once the app exists).
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

# --- 4. echo app (wave 7) ----------------------------------------------------
if kubectl get applications.argoproj.io echo -n argocd >/dev/null 2>&1; then
  HOST="echo.apps.${DOMAIN}"
  REGION="${REGION:-us-central1}"

  # 4a. wildcard certificate issued (staging by default, see ADR 0006)
  kubectl -n istio-ingress wait --for=condition=Ready certificate/wildcard-apps --timeout=300s >/dev/null \
    || fail "Certificate wildcard-apps in istio-ingress is not Ready (kubectl -n istio-ingress describe certificate wildcard-apps)"
  issuer="$(kubectl -n istio-ingress get certificate wildcard-apps -o jsonpath='{.spec.issuerRef.name}')"
  pass "wildcard certificate is Ready (issuer: $issuer)"

  # 4b. DNS points at the reserved ingress IP
  want_ip="${INGRESS_IP:-$(gcloud compute addresses describe idp-ingress --region "$REGION" --project "$PROJECT" --format='value(address)' 2>/dev/null || true)}"
  [ -n "$want_ip" ] || fail "could not determine the reserved ingress IP (set INGRESS_IP or check gcloud access)"
  got_ip="$(dig +short "$HOST" @8.8.8.8 | tail -n 1)"
  [ "$got_ip" = "$want_ip" ] || fail "$HOST resolves to '${got_ip:-nothing}', expected $want_ip"
  pass "$HOST resolves to the reserved ingress IP $want_ip"

  # 4c. HTTPS 200. The staging CA is not in any trust store, so use -k and say so.
  curl_opts=(-s -o /dev/null -w '%{http_code}' --max-time 20)
  case "$issuer" in
    *staging*) curl_opts+=(-k); note=" (certificate is from the Let's Encrypt STAGING CA, so TLS trust was not checked)" ;;
    *) note="" ;;
  esac
  deadline=$((SECONDS + 300)) # the load balancer can lag the Gateway by a few minutes
  while :; do
    code="$(curl "${curl_opts[@]}" "https://${HOST}" || true)"
    [ "$code" = "200" ] && break
    [ "$SECONDS" -ge "$deadline" ] && fail "https://${HOST} returned HTTP ${code:-none} after 300s"
    sleep 10
  done
  pass "https://${HOST} returned 200${note}"
else
  skip "echo app not deployed yet (wave 7)"
fi

echo "verify.sh: all checks passed"
