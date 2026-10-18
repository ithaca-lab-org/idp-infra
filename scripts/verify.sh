#!/usr/bin/env bash
# Post-build checks, run by `make up` and by hand (`make verify`). Deterministic:
# exits non-zero on the first failing check after a polling timeout.
#
# Prints a header for each step, progress while it waits (what is still not ready and
# how long it has been waiting), and a summary of every check at the end, also on failure.
# Steps: (1) cluster access; (2) every Argo CD Application is Synced and Healthy;
#        (3) the Tailscale operator is available; (4) cert-manager is available;
#        (5) echo app: wildcard Certificate Ready, DNS -> reserved IP, HTTPS 200 (once the app exists).
#        (6) identity: Keycloak public issuer answers, admin console and master realm are not routed.
# Bash 3.2 compatible (macOS): no associative arrays, no grep -P.
set -euo pipefail

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
DOMAIN="${DOMAIN:-ithaca-idp.com}"
TIMEOUT="${VERIFY_TIMEOUT:-900}" # seconds to wait for the sync waves to settle
INTERVAL=10
TOTAL_STEPS=6

START=$SECONDS
RESULTS=""
APPS_TABLE=""

elapsed() { printf '%ss' "$((SECONDS - START))"; }
step() { printf '\n==> [%s/%s] %s  (t+%s)\n' "$1" "$TOTAL_STEPS" "$2" "$(elapsed)"; }
info() { printf '    %s\n' "$*"; }
record() { RESULTS="${RESULTS}$(printf '%-5s %s  (t+%s)' "$1" "$2" "$(elapsed)")"$'\n'; }
pass() { record PASS "$*"; printf '    PASS  %s\n' "$*"; }
skip() { record SKIP "$*"; printf '    SKIP  %s\n' "$*"; }
fail() { record FAIL "$*"; printf '    FAIL  %s\n' "$*" >&2; exit 1; }

# Always print what was checked, even when a check failed and the script exits early.
summary() {
  local rc=$?
  printf '\n===== verify.sh summary (took %s) =====\n' "$(elapsed)"
  if [ -n "$APPS_TABLE" ]; then
    printf 'Argo CD applications (name, sync, health):\n'
    printf '%s\n' "$APPS_TABLE" | awk -F'\t' 'NF>=3 {printf "  %-22s %-10s %s\n", $1, $2, $3}'
    printf '\n'
  fi
  printf '%s' "$RESULTS"
  if [ "$rc" -eq 0 ]; then
    printf 'RESULT: all checks passed\n'
  else
    printf 'RESULT: FAILED (see the FAIL line above)\n' >&2
  fi
}
trap summary EXIT

apps_table() {
  kubectl get applications.argoproj.io -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null
}

# --- 1. cluster access --------------------------------------------------------
step 1 "cluster access ($CLUSTER, through the DNS endpoint)"
# Idempotent: makes sure kubectl points at this cluster.
gcloud container clusters get-credentials "$CLUSTER" --dns-endpoint --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 \
  || fail "could not get credentials for $CLUSTER (needs gcloud with --dns-endpoint support)"
pass "kubectl is pointed at cluster $CLUSTER"

# --- 2. Argo CD applications --------------------------------------------------
step 2 "Argo CD applications Synced and Healthy (waiting up to ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT))
wait_start=$SECONDS
last_bad="__none__"
last_print=$SECONDS
while :; do
  APPS_TABLE="$(apps_table || true)"
  total="$(awk -F'\t' 'NF>=3' <<<"$APPS_TABLE" | wc -l | tr -d ' ')"
  bad="$(awk -F'\t' 'NF>=3 && ($2!="Synced" || $3!="Healthy") {printf "%s(%s/%s) ", $1, $2, $3}' <<<"$APPS_TABLE")"
  bad="${bad% }"
  ready=$((total - $(awk -F'\t' 'NF>=3 && ($2!="Synced" || $3!="Healthy")' <<<"$APPS_TABLE" | wc -l | tr -d ' ')))
  if [ "$total" -gt 0 ] && [ -z "$bad" ]; then
    pass "all $total Argo CD applications are Synced and Healthy (after $((SECONDS - wait_start))s)"
    break
  fi
  # Print when something changed, and a heartbeat every 30s so a quiet wait is visible.
  if [ "$bad" != "$last_bad" ] || [ $((SECONDS - last_print)) -ge 30 ]; then
    if [ "$total" -eq 0 ]; then
      info "[$((SECONDS - wait_start))s] no applications yet (is Argo CD syncing the root app?)"
    else
      info "[$((SECONDS - wait_start))s] $ready/$total ready; waiting on: $bad"
    fi
    last_bad="$bad"
    last_print=$SECONDS
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "Argo CD applications not all Synced/Healthy after ${TIMEOUT}s (waiting on: ${bad:-none found})"
  fi
  sleep "$INTERVAL"
done

# --- 3. Tailscale operator (wave 2) ------------------------------------------
step 3 "Tailscale operator"
info "waiting up to 180s for deployment/operator in namespace tailscale"
# Needs Secret tailscale/operator-oauth from scripts/bootstrap-secrets.sh; without it the Pod never starts.
kubectl -n tailscale wait --for=condition=Available deployment/operator --timeout=180s >/dev/null \
  || fail "deployment operator in tailscale is not Available (Secret tailscale/operator-oauth missing? run ./scripts/bootstrap-secrets.sh)"
pass "Tailscale operator deployment is Available"

# --- 4. cert-manager ---------------------------------------------------------
step 4 "cert-manager"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  info "waiting up to 120s for deployment/$d"
  kubectl -n cert-manager wait --for=condition=Available "deployment/$d" --timeout=120s >/dev/null \
    || fail "deployment $d in cert-manager is not Available"
done
pass "cert-manager deployments are Available"

# --- 5. echo app (wave 7) ----------------------------------------------------
step 5 "echo app (certificate, DNS, HTTPS)"
if kubectl get applications.argoproj.io echo -n argocd >/dev/null 2>&1; then
  HOST="echo.apps.${DOMAIN}"
  REGION="${REGION:-us-central1}"

  # 5a. wildcard certificate issued (staging by default, see ADR 0006)
  info "waiting up to 300s for Certificate wildcard-apps in istio-ingress"
  kubectl -n istio-ingress wait --for=condition=Ready certificate/wildcard-apps --timeout=300s >/dev/null \
    || fail "Certificate wildcard-apps in istio-ingress is not Ready (kubectl -n istio-ingress describe certificate wildcard-apps)"
  issuer="$(kubectl -n istio-ingress get certificate wildcard-apps -o jsonpath='{.spec.issuerRef.name}')"
  pass "wildcard certificate is Ready (issuer: $issuer)"

  # 5b. DNS points at the reserved ingress IP
  want_ip="${INGRESS_IP:-$(gcloud compute addresses describe idp-ingress --region "$REGION" --project "$PROJECT" --format='value(address)' 2>/dev/null || true)}"
  [ -n "$want_ip" ] || fail "could not determine the reserved ingress IP (set INGRESS_IP or check gcloud access)"
  got_ip="$(dig +short "$HOST" @8.8.8.8 | tail -n 1)"
  [ "$got_ip" = "$want_ip" ] || fail "$HOST resolves to '${got_ip:-nothing}', expected $want_ip"
  pass "$HOST resolves to the reserved ingress IP $want_ip"

  # 5c. HTTPS 200. The staging CA is not in any trust store, so use -k and say so.
  curl_opts=(-s -o /dev/null -w '%{http_code}' --max-time 20)
  case "$issuer" in
    *staging*) curl_opts+=(-k); note=" (certificate is from the Let's Encrypt STAGING CA, so TLS trust was not checked)" ;;
    *) note="" ;;
  esac
  info "requesting https://${HOST} (the load balancer can lag the Gateway; waiting up to 300s)"
  deadline=$((SECONDS + 300))
  http_start=$SECONDS
  while :; do
    code="$(curl "${curl_opts[@]}" "https://${HOST}" || true)"
    [ "$code" = "200" ] && break
    [ "$SECONDS" -ge "$deadline" ] && fail "https://${HOST} returned HTTP ${code:-none} after 300s"
    info "[$((SECONDS - http_start))s] HTTP ${code:-none}, retrying"
    sleep 10
  done
  pass "https://${HOST} returned 200${note}"
else
  skip "echo app not deployed yet (wave 7)"
fi

# --- 6. identity (waves 8-9) -------------------------------------------------
step 6 "identity (Keycloak public issuer, admin not exposed)"
if kubectl get applications.argoproj.io keycloak -n argocd >/dev/null 2>&1; then
  AUTH_HOST="auth.apps.${DOMAIN}"
  info "waiting up to 600s for statefulset/keycloak in identity"
  kubectl -n identity rollout status statefulset/keycloak --timeout=600s >/dev/null \
    || fail "statefulset keycloak in identity is not ready (Secrets identity/* missing? run ./scripts/bootstrap-secrets.sh)"
  pass "Keycloak is ready"

  id_curl=(-s --max-time 20)
  case "$(kubectl -n istio-ingress get certificate wildcard-apps -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)" in
    *staging*) id_curl+=(-k) ;;
  esac
  disco="https://${AUTH_HOST}/realms/ithaca/.well-known/openid-configuration"
  deadline=$((SECONDS + 300))
  while :; do
    body="$(curl "${id_curl[@]}" "$disco" || true)"
    case "$body" in *"\"issuer\":\"https://${AUTH_HOST}/realms/ithaca\""*) break ;; esac
    [ "$SECONDS" -ge "$deadline" ] && fail "$disco did not return the expected issuer after 300s"
    info "issuer not answering yet, retrying"
    sleep 10
  done
  pass "public issuer is https://${AUTH_HOST}/realms/ithaca"

  for path in /admin/master/console/ /realms/master/.well-known/openid-configuration /metrics; do
    code="$(curl "${id_curl[@]}" -o /dev/null -w '%{http_code}' "https://${AUTH_HOST}${path}" || true)"
    [ "$code" = "404" ] || fail "https://${AUTH_HOST}${path} returned HTTP ${code:-none}, expected 404 (must not be exposed)"
  done
  pass "admin console, master realm and metrics are not exposed publicly (404)"
else
  skip "keycloak not deployed yet (wave 9)"
fi
