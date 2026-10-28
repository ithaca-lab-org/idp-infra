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
#        (7) portal stack: lldap seed, MongoDB, portal, operator, notifier and an end-to-end order smoke test
#            (creates and deletes a throwaway TeamNamespace; skip it with VERIFY_SMOKE=0).
#        (8) vault: vault-0 Running and ready, Vault initialized and unsealed (Cloud KMS), and the
#            VSO demo Secret vault-demo/hello has key message (value never printed). Needs jq.
# Bash 3.2 compatible (macOS): no associative arrays, no grep -P.
set -euo pipefail

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
DOMAIN="${DOMAIN:-ithaca-idp.com}"
TIMEOUT="${VERIFY_TIMEOUT:-900}" # seconds to wait for the sync waves to settle
INTERVAL=10
TOTAL_STEPS=8

START=$SECONDS
RESULTS=""
APPS_TABLE=""
SMOKE_NAME="verify-smoke"
SMOKE_CREATED=""

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
  # Never leave the smoke-test resource behind, also when a check failed.
  if [ -n "$SMOKE_CREATED" ]; then
    kubectl delete teamnamespace "$SMOKE_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
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

# --- 7. portal stack (waves 8-12) --------------------------------------------
step 7 "portal stack (lldap seed, MongoDB, portal, operator, order smoke test)"
if kubectl get applications.argoproj.io portal -n argocd >/dev/null 2>&1; then
  if kubectl -n identity get job lldap-seed >/dev/null 2>&1; then
    info "waiting up to 300s for job/lldap-seed"
    kubectl -n identity wait --for=condition=complete job/lldap-seed --timeout=300s >/dev/null \
      || fail "job lldap-seed did not complete (kubectl -n identity logs job/lldap-seed)"
    pass "lldap seed Job completed (users and groups are in the directory)"
  else
    skip "lldap seed Job not present"
  fi

  info "waiting up to 300s for statefulset/portal-mongo"
  kubectl -n idp-system rollout status statefulset/portal-mongo --timeout=300s >/dev/null \
    || fail "statefulset portal-mongo in idp-system is not ready (kubectl -n idp-system logs portal-mongo-0)"
  pass "portal MongoDB is ready"

  for d in portal-api idp-operator; do
    info "waiting up to 300s for deployment/$d"
    kubectl -n idp-system wait --for=condition=Available "deployment/$d" --timeout=300s >/dev/null \
      || fail "deployment $d in idp-system is not Available (kubectl -n idp-system logs deploy/$d)"
  done
  pass "portal-api and idp-operator are Available"

  # Order events: portal-api publishes, the notifier subscribes. Only present once idp-gitops
  # deploys the notifier. The smoke order below bypasses the portal, so it sends no event; this
  # checks that both sides started cleanly and reports whether email sending is on.
  if kubectl -n idp-system get deployment notifier >/dev/null 2>&1; then
    info "waiting up to 300s for deployment/notifier"
    kubectl -n idp-system wait --for=condition=Available deployment/notifier --timeout=300s >/dev/null       || fail "deployment notifier in idp-system is not Available (kubectl -n idp-system logs deploy/notifier)"
    nlog=""
    deadline=$((SECONDS + 90))
    while :; do
      nlog="$(kubectl -n idp-system logs deploy/notifier 2>&1 || true)"
      case "$nlog" in *"notifier started"*) break ;; esac
      [ "$SECONDS" -ge "$deadline" ] && fail "notifier did not report 'notifier started' (kubectl -n idp-system logs deploy/notifier)"
      info "notifier is not subscribed yet, retrying"
      sleep 5
    done
    case "$nlog" in
      *" ERROR "*) fail "notifier logged errors (a Pub/Sub or Workload Identity problem?): $(printf '%s\n' "$nlog" | grep ' ERROR ' | head -n 1)" ;;
    esac
    case "$nlog" in
      *"email sending is OFF"*) mode="email sending is OFF (logs only)" ;;
      *"email sending is ON"*) mode="email sending is ON" ;;
      *) fail "notifier did not report its email mode" ;;
    esac
    plog="$(kubectl -n idp-system logs deploy/portal-api 2>&1 || true)"
    case "$plog" in
      *"publishing order events"*) ;;
      *) fail "portal-api is not publishing order events (PUBSUB_TOPIC unset or the image predates idp-portal #16): kubectl -n idp-system logs deploy/portal-api" ;;
    esac
    pass "notifier is subscribed (${mode}); portal-api publishes order events"
  else
    skip "notifier not deployed yet"
  fi

  kubectl wait --for=condition=Established crd/teamnamespaces.idp.ithaca-idp.com --timeout=60s >/dev/null \
    || fail "CRD teamnamespaces.idp.ithaca-idp.com is not established"
  kubectl get validatingadmissionpolicy idp-operator-scope >/dev/null 2>&1 \
    || fail "ValidatingAdmissionPolicy idp-operator-scope is missing: the operator would run unconfined"
  pass "TeamNamespace CRD is established and the operator admission policy is present"

  PORTAL_HOST="portal.apps.${DOMAIN}"
  p_curl=(-s -o /dev/null -w '%{http_code}' --max-time 20)
  case "$(kubectl -n istio-ingress get certificate wildcard-apps -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)" in
    *staging*) p_curl+=(-k) ;;
  esac
  for want in "/healthz 200" "/auth/login 302" "/api/orders 401"; do
    path="${want% *}"; code_want="${want#* }"
    deadline=$((SECONDS + 180))
    while :; do
      code="$(curl "${p_curl[@]}" "https://${PORTAL_HOST}${path}" || true)"
      [ "$code" = "$code_want" ] && break
      [ "$SECONDS" -ge "$deadline" ] && fail "https://${PORTAL_HOST}${path} returned HTTP ${code:-none}, expected ${code_want}"
      info "${path}: HTTP ${code:-none}, retrying"
      sleep 10
    done
  done
  pass "portal answers: /healthz 200, /auth/login redirects, /api/orders refuses anonymous callers (401)"

  if [ "${VERIFY_SMOKE:-1}" = "0" ]; then
    skip "order smoke test disabled (VERIFY_SMOKE=0)"
  else
    SMOKE_CREATED=1
    kubectl apply -f - >/dev/null <<EOF || fail "could not create the smoke-test TeamNamespace"
apiVersion: idp.ithaca-idp.com/v1alpha1
kind: TeamNamespace
metadata:
  name: ${SMOKE_NAME}
spec:
  businessUnit: verify-bu
  owner: verify@example.com
  size: small
  orderId: ORD-0000-000000
EOF
    info "waiting up to 180s for the operator to reconcile ${SMOKE_NAME}"
    kubectl wait --for=jsonpath='{.status.phase}'=Ready "teamnamespace/${SMOKE_NAME}" --timeout=180s >/dev/null \
      || fail "TeamNamespace ${SMOKE_NAME} did not become Ready (kubectl get teamnamespace ${SMOKE_NAME} -o yaml; kubectl -n idp-system logs deploy/idp-operator)"
    kubectl -n "$SMOKE_NAME" get resourcequota/idp-quota limitrange/idp-limits networkpolicy/idp-default-deny-ingress rolebinding/idp-namespace-admin >/dev/null \
      || fail "namespace ${SMOKE_NAME} is missing quota, limits, network policy or the owner binding"
    pass "order smoke test: namespace created with quota, limits, default-deny policy and owner binding"
    kubectl delete teamnamespace "$SMOKE_NAME" --wait=false >/dev/null || fail "could not delete the smoke-test TeamNamespace"
    kubectl wait --for=delete "namespace/${SMOKE_NAME}" --timeout=180s >/dev/null \
      || fail "namespace ${SMOKE_NAME} was not removed after its TeamNamespace was deleted"
    SMOKE_CREATED=""
    pass "order smoke test: deleting the TeamNamespace removed the namespace"
  fi
else
  skip "portal not deployed yet (wave 11)"
fi

# --- 8. vault ---------------------------------------------------------------
step 8 "vault (initialized, unsealed by Cloud KMS, VSO demo secret)"
if kubectl get applications.argoproj.io vault -n argocd >/dev/null 2>&1; then
  command -v jq >/dev/null 2>&1 || fail "jq not found on PATH (needed to read vault status)"

  # The chart's StatefulSet uses the OnDelete update strategy, so `rollout status` does not work:
  # poll the ready count instead. vault-0 is Ready even while sealed or uninitialized (the readiness
  # probe accepts those states so the init can reach it); the vault status check below catches them.
  info "waiting up to 600s for statefulset/vault in vault"
  deadline=$((SECONDS + 600))
  while :; do
    ready="$(kubectl -n vault get statefulset vault -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
    case "$ready" in
      /* | "" | 0/*) ;;
      *) [ "${ready%/*}" = "${ready#*/}" ] && break ;;
    esac
    [ "$SECONDS" -ge "$deadline" ] \
      && fail "statefulset vault in vault is not ready (${ready:-not found}; not initialized? run ./scripts/bootstrap-secrets.sh; kubectl -n vault logs vault-0)"
    info "statefulset vault ready ${ready:-?}, retrying"
    sleep "$INTERVAL"
  done
  phase="$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = Running ] || fail "pod vault-0 is ${phase:-missing}, expected Running"
  pass "statefulset vault is ready and vault-0 is Running"

  # Exit code 0 = unsealed, 2 = sealed, 1 = error; the status output holds no secrets.
  if vstatus="$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null)"; then vrc=0; else vrc=$?; fi
  vinit="$(printf '%s' "$vstatus" | jq -r '.initialized' 2>/dev/null || true)"
  vsealed="$(printf '%s' "$vstatus" | jq -r '.sealed' 2>/dev/null || true)"
  vtype="$(printf '%s' "$vstatus" | jq -r '.type' 2>/dev/null || true)"
  [ "$vinit" = true ] || fail "Vault is not initialized (vault status exit $vrc): run ./scripts/bootstrap-secrets.sh"
  [ "$vrc" = 0 ] && [ "$vsealed" = false ] \
    || fail "Vault is initialized but sealed (vault status exit $vrc): KMS auto-unseal failing, see kubectl -n vault logs vault-0 and docs/vault.md"
  pass "Vault is initialized and unsealed (seal type: ${vtype:-unknown})"

  # Only checks that the key exists and is not empty: the template never outputs the value.
  info "waiting up to 180s for Secret vault-demo/hello (synced by VSO from kv/vault-demo/hello)"
  deadline=$((SECONDS + 180))
  while :; do
    has="$(kubectl -n vault-demo get secret hello -o go-template='{{with .data}}{{if .message}}yes{{end}}{{end}}' 2>/dev/null || true)"
    [ "$has" = yes ] && break
    [ "$SECONDS" -ge "$deadline" ] \
      && fail "Secret vault-demo/hello with key message did not appear after 180s (kubectl -n vault-demo describe vaultstaticsecret; kubectl -n vault get jobs; docs/vault.md)"
    info "Secret vault-demo/hello not synced yet, retrying"
    sleep "$INTERVAL"
  done
  pass "VSO synced Secret vault-demo/hello (key message present, value not shown)"
else
  skip "vault not deployed yet"
fi
