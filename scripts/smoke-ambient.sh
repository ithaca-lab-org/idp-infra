#!/usr/bin/env bash
# Istio ambient smoke test for the idp GKE cluster (Standard, zonal, Dataplane V2,
# Gateway API standard channel, private Spot nodes, Workload Identity, Cloud NAT).
#
#   scripts/smoke-ambient.sh install   # Helm: istio base, istiod (ambient), istio-cni, ztunnel
#   scripts/smoke-ambient.sh deploy    # namespace ambient-smoke + client, client-other, echo, echo-v2
#   scripts/smoke-ambient.sh test      # checks 1-5, PASS/FAIL per check, exit 0 only if all pass
#   scripts/smoke-ambient.sh cleanup   # DESTRUCTIVE: delete the namespace, uninstall the releases
#
# Checklist, expected output and the decision table: docs/smoke-ambient.md
#
# Human-only, on a `make up` cluster; `make down` afterwards. Every subcommand is
# idempotent. Only `cleanup` deletes anything (and asks first). `test` resets its own
# test policies by re-applying them in an "open" form, never by deleting them.
#
# Items marked UNVERIFIED were not checked against Istio/GKE docs (none are vendored
# in this repo). Confirm them against the docs for the pinned Istio version.
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions. Bump deliberately: read the Istio release notes, check the
# supported Kubernetes range against the cluster's REGULAR-channel version, and
# install the matching istioctl. Not overridable from the environment on purpose.
# ---------------------------------------------------------------------------
# UNVERIFIED: 1.27.1 is a known release, but it may not support the Kubernetes
# minor that the REGULAR channel ships when this runs. Pick the newest patch of a
# supported Istio minor that lists the cluster's Kubernetes version.
ISTIO_VERSION="1.27.1"
HELM_REPO_NAME="istio"
HELM_REPO_URL="https://istio-release.storage.googleapis.com/charts"
# UNVERIFIED: tags believed to exist; pin by digest once pulled once.
CLIENT_IMAGE="curlimages/curl:8.10.1"
ECHO_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.53"

# ---------------------------------------------------------------------------
# Cluster (matches envs/dev/terraform.tfvars).
# ---------------------------------------------------------------------------
PROJECT_ID="project-324502ff-9928-4b17-a89"
ZONE="us-central1-a"
CLUSTER="idp"
# UNVERIFIED: assumes --dns-endpoint keeps the usual gke_<project>_<zone>_<name> context name.
EXPECTED_CONTEXT="gke_${PROJECT_ID}_${ZONE}_${CLUSTER}"
GET_CREDS="gcloud container clusters get-credentials ${CLUSTER} --dns-endpoint --zone ${ZONE} --project ${PROJECT_ID}"

ISTIO_NS="istio-system"
NS="ambient-smoke"
TRUST_DOMAIN="cluster.local" # Istio default; the IDP will set a custom one later (IDP_NOTES #03).
ECHO_URL="http://echo.${NS}.svc.cluster.local/hostname"
ECHO_V2_URL="http://echo-v2.${NS}.svc.cluster.local/hostname"
APP_PORT=8080          # agnhost netexec --http-port
HBONE_PORT=15008       # UNVERIFIED (well known): ztunnel inbound HBONE port
PROBE_SNAT_IP="169.254.7.127" # UNVERIFIED (well known): istio-cni SNATs kubelet probes to this address
NP_NAME="echo-ingress"
AUTHZ_NAME="echo-l4"
WAYPOINT="waypoint"
ROUTE_HEADER="x-smoke-route"

# ---------------------------------------------------------------------------
# Timeouts (explicit; override from the environment if the cluster is slow).
# ---------------------------------------------------------------------------
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-30s}"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-180s}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-5}"
POLL_TIMEOUT="${POLL_TIMEOUT:-90}"     # seconds for a policy/route change to take effect
POLL_INTERVAL="${POLL_INTERVAL:-3}"
STABLE_ATTEMPTS="${STABLE_ATTEMPTS:-3}" # consecutive identical results required
SETTLE_SECONDS="${SETTLE_SECONDS:-10}"  # after re-applying baseline policies
PROBE_SETTLE="${PROBE_SETTLE:-30}"      # > readiness period * failureThreshold (5s * 3)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH (see docs/smoke-ambient.md prerequisites)"; }
kc() { kubectl --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" "$@"; }

preflight() {
  need kubectl
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [ "$ctx" != "$EXPECTED_CONTEXT" ] && [ "${SMOKE_ALLOW_ANY_CONTEXT:-0}" != "1" ]; then
    die "kube context is '${ctx:-<none>}', expected '${EXPECTED_CONTEXT}'. Run: ${GET_CREDS}  (or set SMOKE_ALLOW_ANY_CONTEXT=1 if the name differs)"
  fi
  kc get namespace default >/dev/null || die "cluster API not reachable. Run: ${GET_CREDS}"
}

istioctl_present() { command -v istioctl >/dev/null 2>&1; }

istioctl_check() {
  if ! istioctl_present; then
    log "WARN istioctl not found: check 2 falls back to ztunnel logs only"
    return 0
  fi
  local v
  v="$(istioctl version --remote=false 2>/dev/null | head -n1 || true)"
  case "$v" in
    *"$ISTIO_VERSION"*) log "istioctl client matches chart version ${ISTIO_VERSION}" ;;
    *) log "WARN istioctl client '${v}' does not match chart version ${ISTIO_VERSION}" ;;
  esac
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
cmd_install() {
  preflight
  need helm
  istioctl_check

  log "helm repo ${HELM_REPO_NAME} -> ${HELM_REPO_URL}"
  helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" --force-update >/dev/null
  helm repo update "$HELM_REPO_NAME" >/dev/null

  kc create namespace "$ISTIO_NS" --dry-run=client -o yaml | kc apply -f -

  # GKE only admits system-node-critical pods (istio-cni, ztunnel) in namespaces
  # that have a ResourceQuota scoped to that PriorityClass.
  # UNVERIFIED: shape copied from memory of Istio's GKE platform-prerequisites page.
  kc apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gcp-critical-pods
  namespace: ${ISTIO_NS}
spec:
  hard:
    pods: "1000"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values:
          - system-node-critical
EOF

  # Gateway API CRDs are owned by GKE (gateway_api_config CHANNEL_STANDARD): do NOT
  # install them here. istio/base installs only Istio's own CRDs.
  local common=(--namespace "$ISTIO_NS" --version "$ISTIO_VERSION" --wait --timeout "$HELM_TIMEOUT")

  log "helm istio-base ${ISTIO_VERSION}"
  helm upgrade --install istio-base "${HELM_REPO_NAME}/base" "${common[@]}"

  # UNVERIFIED: profile=ambient and global.platform=gke as chart values (Helm ignores
  # unknown keys unless the chart ships a values schema).
  log "helm istiod ${ISTIO_VERSION} (profile=ambient, platform=gke)"
  helm upgrade --install istiod "${HELM_REPO_NAME}/istiod" "${common[@]}" \
    --set profile=ambient --set global.platform=gke

  # UNVERIFIED: global.platform=gke sets the GKE CNI bin dir (/home/kubernetes/bin).
  # Whether Dataplane V2 needs any further istio-cni value is exactly what this test probes.
  log "helm istio-cni ${ISTIO_VERSION} (profile=ambient, platform=gke)"
  helm upgrade --install istio-cni "${HELM_REPO_NAME}/cni" "${common[@]}" \
    --set profile=ambient --set global.platform=gke

  # UNVERIFIED: whether the ztunnel chart reads global.platform.
  log "helm ztunnel ${ISTIO_VERSION} (platform=gke)"
  helm upgrade --install ztunnel "${HELM_REPO_NAME}/ztunnel" "${common[@]}" \
    --set global.platform=gke

  log "waiting for readiness (timeout ${ROLLOUT_TIMEOUT} each)"
  kubectl -n "$ISTIO_NS" rollout status deployment/istiod --timeout="$ROLLOUT_TIMEOUT"
  kubectl -n "$ISTIO_NS" rollout status daemonset/istio-cni-node --timeout="$ROLLOUT_TIMEOUT" # UNVERIFIED name
  kubectl -n "$ISTIO_NS" rollout status daemonset/ztunnel --timeout="$ROLLOUT_TIMEOUT"

  # istiod creates the istio-waypoint GatewayClass itself (needed by check 5).
  local waited=0
  until kc get gatewayclass istio-waypoint >/dev/null 2>&1; do
    if [ "$waited" -ge "$POLL_TIMEOUT" ]; then
      log "WARN GatewayClass istio-waypoint not present after ${POLL_TIMEOUT}s; check 5 will fail"
      break
    fi
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done

  helm list -n "$ISTIO_NS"
  log "install done"
}

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
client_manifest() { # $1 = name (also ServiceAccount name)
  cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $1
  namespace: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: ${NS}
  labels: {app: $1, smoke-role: client}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $1}
  template:
    metadata:
      labels: {app: $1, smoke-role: client}
    spec:
      serviceAccountName: $1
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
      containers:
        - name: curl
          image: ${CLIENT_IMAGE}
          command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
EOF
}

echo_manifest() { # $1 = name (echo | echo-v2)
  cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $1
  namespace: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: ${NS}
  labels: {app: $1}
spec:
  replicas: 1
  selector:
    matchLabels: {app: $1}
  template:
    metadata:
      labels: {app: $1}
    spec:
      serviceAccountName: $1
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
      # Prefer a different node from the clients so traffic crosses two ztunnels.
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: {smoke-role: client}
      containers:
        - name: echo
          image: ${ECHO_IMAGE}
          args: ["netexec", "--http-port=${APP_PORT}"]
          ports:
            - {name: http, containerPort: ${APP_PORT}}
          readinessProbe:
            httpGet: {path: /hostname, port: ${APP_PORT}}
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: $1
  namespace: ${NS}
  labels: {app: $1}
spec:
  type: ClusterIP
  selector: {app: $1}
  ports:
    - name: http
      port: 80
      targetPort: ${APP_PORT}
      protocol: TCP
EOF
}

cmd_deploy() {
  preflight
  kc get deployment istiod -n "$ISTIO_NS" >/dev/null 2>&1 || die "istiod not found: run '$0 install' first"

  log "applying namespace ${NS} (istio.io/dataplane-mode=ambient) and workloads"
  {
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    istio.io/dataplane-mode: ambient
EOF
    client_manifest client
    client_manifest client-other
    echo_manifest echo
    echo_manifest echo-v2
  } | kc apply -f -

  local d
  for d in client client-other echo echo-v2; do
    kubectl -n "$NS" rollout status "deployment/${d}" --timeout="$ROLLOUT_TIMEOUT"
  done
  kc -n "$NS" get pods -o wide
  log "deploy done"
}

# ---------------------------------------------------------------------------
# test: policy manifests (re-applied, never deleted, so re-runs are idempotent)
# ---------------------------------------------------------------------------
apply_authz() { # $1 = allow-all | client-only | client-and-sa <sa>
  local rules
  case "$1" in
    allow-all)
      rules="    - {}" ;;
    client-only)
      rules="    - from:
        - source:
            principals: [\"${TRUST_DOMAIN}/ns/${NS}/sa/client\"]" ;;
    client-and-sa)
      rules="    - from:
        - source:
            principals: [\"${TRUST_DOMAIN}/ns/${NS}/sa/client\", \"${TRUST_DOMAIN}/ns/${NS}/sa/$2\"]" ;;
    *) die "apply_authz: unknown mode $1" ;;
  esac
  # L4-only (principals) policy with a workload selector: enforced by ztunnel on
  # echo's node, no waypoint needed.
  kc apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ${AUTHZ_NAME}
  namespace: ${NS}
spec:
  selector:
    matchLabels: {app: echo}
  action: ALLOW
  rules:
${rules}
EOF
}

apply_netpol() { # $1 = open | hbone-only
  local ingress
  case "$1" in
    open)
      ingress="    - {}" ;;
    hbone-only)
      # Mesh traffic reaches echo only as HBONE on 15008. The app port is opened
      # only to the istio-cni probe SNAT address so kubelet readiness probes pass.
      ingress="    - ports:
        - {protocol: TCP, port: ${HBONE_PORT}}
    - from:
        - ipBlock: {cidr: ${PROBE_SNAT_IP}/32}
      ports:
        - {protocol: TCP, port: ${APP_PORT}}" ;;
    *) die "apply_netpol: unknown mode $1" ;;
  esac
  kc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NP_NAME}
  namespace: ${NS}
spec:
  podSelector:
    matchLabels: {app: echo}
  policyTypes: [Ingress]
  ingress:
${ingress}
EOF
}

reset_baseline() {
  log "resetting test policies to baseline (allow-all AuthorizationPolicy, open NetworkPolicy, no waypoint on echo)"
  kc -n "$NS" label service echo istio.io/use-waypoint- >/dev/null 2>&1 || true
  apply_authz allow-all >/dev/null
  apply_netpol open >/dev/null
  sleep "$SETTLE_SECONDS"
}

# ---------------------------------------------------------------------------
# test: request helpers
# ---------------------------------------------------------------------------
LAST_CODE=""
LAST_BODY=""

# req <client-deployment> <url> [header]; returns 0 only on HTTP 200.
req() {
  local from="$1" url="$2" hdr="${3:-}" out rc=0
  local extra=()
  if [ -n "$hdr" ]; then extra=(-H "$hdr"); fi
  out="$(kc -n "$NS" exec "deployment/${from}" -c curl -- \
    curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    ${extra[@]+"${extra[@]}"} -w '\n%{http_code}' "$url" 2>&1)" || rc=$?
  LAST_CODE="$(printf '%s\n' "$out" | tail -n1)"
  LAST_BODY="$(printf '%s\n' "$out" | sed '$d' | tr '\n' ' ')"
  [ "$rc" -eq 0 ] && [ "$LAST_CODE" = "200" ]
}

# expect_allow <from> <url> [header] [body-prefix]: poll until 200 (and body
# prefix, if given), then require STABLE_ATTEMPTS consecutive matches.
matches() { # $1 = body prefix ("" = any)
  [ -z "$1" ] && return 0
  case "$LAST_BODY" in "$1"*) return 0 ;; *) return 1 ;; esac
}

expect_allow() {
  local from="$1" url="$2" hdr="${3:-}" prefix="${4:-}" waited=0 i
  until req "$from" "$url" "$hdr" && matches "$prefix"; do
    if [ "$waited" -ge "$POLL_TIMEOUT" ]; then
      log "  ${from} -> ${url}${hdr:+ [$hdr]}: not allowed after ${POLL_TIMEOUT}s (code=${LAST_CODE} body=${LAST_BODY})"
      return 1
    fi
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done
  for i in $(seq 1 "$STABLE_ATTEMPTS"); do
    if ! { req "$from" "$url" "$hdr" && matches "$prefix"; }; then
      log "  ${from} -> ${url}${hdr:+ [$hdr]}: flapped on stable attempt ${i} (code=${LAST_CODE} body=${LAST_BODY})"
      return 1
    fi
  done
  log "  ${from} -> ${url}${hdr:+ [$hdr]}: allowed (${LAST_BODY})"
  return 0
}

expect_deny() {
  local from="$1" url="$2" waited=0 i
  while req "$from" "$url"; do
    if [ "$waited" -ge "$POLL_TIMEOUT" ]; then
      log "  ${from} -> ${url}: STILL ALLOWED after ${POLL_TIMEOUT}s (body=${LAST_BODY})"
      return 1
    fi
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done
  for i in $(seq 1 "$STABLE_ATTEMPTS"); do
    if req "$from" "$url"; then
      log "  ${from} -> ${url}: allowed on stable attempt ${i} (body=${LAST_BODY})"
      return 1
    fi
  done
  log "  ${from} -> ${url}: denied (last: code=${LAST_CODE} ${LAST_BODY})"
  return 0
}

ztunnel_on_node() { # $1 = node name
  kc -n "$ISTIO_NS" get pods -l app=ztunnel --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

echo_ztunnel() {
  local node
  node="$(kc -n "$NS" get pods -l app=echo -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
  [ -n "$node" ] && ztunnel_on_node "$node"
}

ztunnel_logs() { # $1 = ztunnel pod, $2 = since
  [ -n "$1" ] || return 0
  kc -n "$ISTIO_NS" logs "$1" --since="$2" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# test: results
# ---------------------------------------------------------------------------
RESULTS=""
FAILED=0
record() { # $1 = check, $2 = PASS|FAIL, $3 = message
  printf '\nCHECK %s %s: %s\n' "$1" "$2" "$3"
  RESULTS="${RESULTS}CHECK $1 $2: $3
"
  if [ "$2" != "PASS" ]; then FAILED=1; fi
}

# ---------------------------------------------------------------------------
# Check 1: no sidecars, pods enrolled in ambient, ztunnel Ready on every node.
# ---------------------------------------------------------------------------
check_1() {
  log "== check 1: no sidecars (1/1), ambient redirection, ztunnel/istio-cni Ready on every node"
  local ok=1 line name containers inits redir ready count=0

  # Exclude the waypoint pod (it is the mesh proxy itself).
  # UNVERIFIED: annotation ambient.istio.io/redirection=enabled is set by istio-cni on enrolled pods.
  while IFS='|' read -r name containers inits redir ready; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    local n
    n="$(printf '%s\n' "$containers" | wc -w | tr -d ' ')"
    if [ "$n" != "1" ] || [ "$ready" != "true" ]; then
      log "  ${name}: containers='${containers}' ready='${ready}' (want exactly 1, Ready)"; ok=0
    fi
    case " $containers $inits " in
      *" istio-proxy "*|*" istio-init "*|*" istio-validation "*) log "  ${name}: sidecar/init present ('${containers}' / '${inits}')"; ok=0 ;;
    esac
    if [ "$redir" != "enabled" ]; then
      log "  ${name}: ambient.istio.io/redirection='${redir}' (want enabled)"; ok=0
    fi
    log "  ${name}: containers=[${containers}] init=[${inits}] redirection=${redir:-<none>} ready=${ready}"
  done <<EOF
$(kc -n "$NS" get pods -l '!gateway.networking.k8s.io/gateway-name' -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.containers[*].name}{"|"}{.spec.initContainers[*].name}{"|"}{.metadata.annotations.ambient\.istio\.io/redirection}{"|"}{.status.containerStatuses[*].ready}{"\n"}{end}' || true)
EOF
  if [ "$count" -lt 4 ]; then log "  expected >= 4 pods in ${NS}, found ${count}"; ok=0; fi

  local nodes zt cni node
  nodes="$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)"
  # UNVERIFIED: pod labels app=ztunnel and k8s-app=istio-cni-node.
  zt="$(kc -n "$ISTIO_NS" get pods -l app=ztunnel -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.status.containerStatuses[*].ready}{"\n"}{end}' || true)"
  cni="$(kc -n "$ISTIO_NS" get pods -l k8s-app=istio-cni-node -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.status.containerStatuses[*].ready}{"\n"}{end}' || true)"
  for node in $nodes; do
    if printf '%s\n' "$zt" | grep -qx "${node}|true"; then
      log "  node ${node}: ztunnel Ready"
    else
      log "  node ${node}: ztunnel NOT Ready or missing"; ok=0
    fi
    if ! printf '%s\n' "$cni" | grep -qx "${node}|true"; then
      log "  node ${node}: istio-cni-node NOT Ready or missing"; ok=0
    fi
  done

  if [ "$ok" = 1 ]; then
    record 1 PASS "all ${count} app pods are 1/1 with no istio-proxy, enrolled in ambient; ztunnel and istio-cni Ready on every node"
  else
    record 1 FAIL "see lines above (sidecar present, pod not enrolled, or ztunnel/istio-cni missing on a node)"
  fi
}

# ---------------------------------------------------------------------------
# Check 2: client -> echo via ClusterIP DNS name, and proof it went through ztunnel.
# ---------------------------------------------------------------------------
check_2() {
  log "== check 2: client -> ${ECHO_URL} through ztunnel (HBONE)"
  local ok=1 evidence=""

  expect_allow client "$ECHO_URL" "" "echo-" || ok=0
  # Baseline for check 3: client-other must work before any deny policy exists.
  expect_allow client-other "$ECHO_URL" "" "echo-" || { log "  client-other cannot reach echo even at baseline"; ok=0; }

  # Evidence 1: istioctl view of ztunnel's workload table.
  # UNVERIFIED: subcommand/flag spelling and the PROTOCOL column value HBONE.
  if istioctl_present; then
    local table pod missing=0
    table="$(istioctl ztunnel-config workloads -i "$ISTIO_NS" 2>/dev/null | grep -E "^${NS}[[:space:]]" || true)"
    printf '%s\n' "$table" | sed 's/^/    /' >&2
    for pod in $(kc -n "$NS" get pods -l '!gateway.networking.k8s.io/gateway-name' -o jsonpath='{.items[*].metadata.name}' || true); do
      printf '%s\n' "$table" | grep -F "$pod" | grep -q HBONE || { log "  istioctl: ${pod} not listed with HBONE"; missing=1; }
    done
    if [ -n "$table" ] && [ "$missing" = 0 ]; then evidence="istioctl ztunnel-config (all pods HBONE)"; fi
  fi

  # Evidence 2: ztunnel access log on echo's node.
  # UNVERIFIED: ztunnel logs "connection complete" at info with src.identity="spiffe://..." fields.
  local zt lines
  zt="$(echo_ztunnel || true)"
  lines="$(ztunnel_logs "$zt" 5m | grep -F 'connection complete' | grep -E "spiffe://[^\"]*/ns/${NS}/sa/client\"" | grep -F 'echo' | tail -n 3 || true)"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines" | sed 's/^/    /' >&2
    evidence="${evidence:+$evidence + }ztunnel log on ${zt}"
  else
    log "  no matching 'connection complete' line from sa/client in ${zt:-<no ztunnel found>} logs (last 5m)"
  fi

  if [ "$ok" = 1 ] && [ -n "$evidence" ]; then
    record 2 PASS "client -> echo HTTP 200 via ClusterIP DNS; ztunnel evidence: ${evidence}"
  elif [ "$ok" = 1 ]; then
    record 2 FAIL "HTTP 200 but NO ztunnel evidence (no istioctl HBONE entry, no ztunnel access log): traffic may not be in the mesh"
  else
    record 2 FAIL "client or client-other could not reach echo at baseline (code=${LAST_CODE})"
  fi
}

# ---------------------------------------------------------------------------
# Check 3 (DECISIVE): L4 AuthorizationPolicy enforced by ztunnel for ClusterIP traffic.
# ---------------------------------------------------------------------------
check_3() {
  log "== check 3 (DECISIVE): L4 AuthorizationPolicy on echo allows only sa/client"
  local ok=1 bypass=0 control=1
  apply_authz client-only

  # Control: client-other is healthy (echo-v2 has no policy).
  expect_allow client-other "$ECHO_V2_URL" "" "echo-v2-" || { control=0; ok=0; }
  expect_allow client "$ECHO_URL" "" "echo-" || ok=0
  if ! expect_deny client-other "$ECHO_URL"; then ok=0; bypass=1; fi

  local zt
  zt="$(echo_ztunnel || true)"
  # UNVERIFIED: wording of ztunnel deny log lines.
  ztunnel_logs "$zt" 3m | grep -iE 'policy rejection|rbac|denied|not allowed' | tail -n 3 | sed 's/^/    /' >&2 || true

  if [ "$ok" = 1 ]; then
    record 3 PASS "client allowed, client-other denied by ztunnel: ClusterIP traffic is intercepted and policy-enforced"
  elif [ "$bypass" = 1 ]; then
    record 3 FAIL "client-other REACHED echo despite an ALLOW-only-sa/client policy. ClusterIP traffic is bypassing ztunnel enforcement. Prime suspect: GKE Dataplane V2 (Cilium eBPF) socket-level load balancing (socketLB) and/or eBPF service handling steering the connection around istio-cni's in-pod redirection, so echo's ztunnel never sees it. Do NOT build on ambient on this cluster until resolved; see the decision table in docs/smoke-ambient.md."
  elif [ "$control" = 0 ]; then
    record 3 FAIL "control failed: client-other cannot reach echo-v2 (no policy), so the deny result is meaningless"
  else
    record 3 FAIL "client (the allowed principal) was denied: check trust domain '${TRUST_DOMAIN}' and principal spelling"
  fi
}

# ---------------------------------------------------------------------------
# Check 4: Kubernetes NetworkPolicy (Dataplane V2) allowing only HBONE + probe SNAT.
# ---------------------------------------------------------------------------
check_4() {
  log "== check 4: NetworkPolicy on echo allows only TCP ${HBONE_PORT} (HBONE) and ${PROBE_SNAT_IP}/32 -> ${APP_PORT}"
  local ok=1 why=""
  apply_netpol hbone-only
  sleep "$SETTLE_SECONDS"

  expect_allow client "$ECHO_URL" "" "echo-" || { ok=0; why="${why} client blocked (HBONE ${HBONE_PORT} not admitted, or traffic arrives on ${APP_PORT} i.e. outside the mesh);"; }
  expect_deny client-other "$ECHO_URL" || { ok=0; why="${why} client-other allowed;"; }

  log "  waiting ${PROBE_SETTLE}s, then checking echo stays Ready (kubelet probes SNAT'd to ${PROBE_SNAT_IP})"
  sleep "$PROBE_SETTLE"
  local ready
  ready="$(kc -n "$NS" get pods -l app=echo -o jsonpath='{.items[*].status.containerStatuses[*].ready}' || true)"
  case " $ready " in
    *" false "*|"  ") ok=0; why="${why} echo NotReady under the policy (probe SNAT address not admitted by Dataplane V2);" ;;
  esac
  log "  echo container ready: ${ready}"

  if [ "$ok" = 1 ]; then
    record 4 PASS "with HBONE-only NetworkPolicy: client allowed, client-other denied, echo stays Ready"
  else
    record 4 FAIL "${why# }"
  fi
}

# ---------------------------------------------------------------------------
# Check 5: L7 via a waypoint (Gateway API, istio-waypoint) + HTTPRoute header match.
# ---------------------------------------------------------------------------
check_5() {
  log "== check 5: waypoint (gatewayClassName istio-waypoint) + HTTPRoute header match"
  local ok=1 why=""

  kc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${WAYPOINT}
  namespace: ${NS}
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: ${HBONE_PORT}
      protocol: HBONE
EOF
  if ! kubectl -n "$NS" wait "gateway/${WAYPOINT}" --for=condition=Programmed=True --timeout="$ROLLOUT_TIMEOUT"; then
    record 5 FAIL "waypoint Gateway not Programmed within ${ROLLOUT_TIMEOUT} (GatewayClass istio-waypoint missing, or GKE's Gateway API CRD version too old for this Istio)"
    return 0
  fi

  # Echo's ztunnel now sees the waypoint's identity, not client's: allow it at L4.
  # UNVERIFIED: waypoint pods carry gateway.networking.k8s.io/gateway-name=<name>.
  local wp_sa
  wp_sa="$(kc -n "$NS" get pods -l "gateway.networking.k8s.io/gateway-name=${WAYPOINT}" -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || true)"
  if [ -z "$wp_sa" ]; then
    record 5 FAIL "could not find the waypoint pod/ServiceAccount (label gateway.networking.k8s.io/gateway-name=${WAYPOINT})"
    return 0
  fi
  log "  waypoint ServiceAccount: ${wp_sa}"
  apply_authz client-and-sa "$wp_sa"

  kc -n "$NS" label service echo "istio.io/use-waypoint=${WAYPOINT}" --overwrite

  # GAMMA: an HTTPRoute whose parent is the Service is programmed into the waypoint.
  kc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-header-route
  namespace: ${NS}
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: echo
      port: 80
  rules:
    - matches:
        - headers:
            - type: Exact
              name: ${ROUTE_HEADER}
              value: v2
      backendRefs:
        - name: echo-v2
          port: 80
    - backendRefs:
        - name: echo
          port: 80
EOF

  expect_allow client "$ECHO_URL" "${ROUTE_HEADER}: v2" "echo-v2-" || { ok=0; why="${why} header request not routed to echo-v2;"; }
  # Without the header the default rule must still land on echo (not echo-v2).
  local i
  for i in $(seq 1 "$STABLE_ATTEMPTS"); do
    if ! req client "$ECHO_URL" || ! matches "echo-" || matches "echo-v2-"; then
      ok=0; why="${why} default route did not return echo (got code=${LAST_CODE} ${LAST_BODY});"; break
    fi
  done

  if istioctl_present; then
    # UNVERIFIED: 'services' view shows the WAYPOINT column for echo.
    istioctl ztunnel-config services -i "$ISTIO_NS" 2>/dev/null | grep -E "^${NS}[[:space:]]+echo[[:space:]]" | sed 's/^/    /' >&2 || true
  fi

  if [ "$ok" = 1 ]; then
    record 5 PASS "waypoint Programmed; '${ROUTE_HEADER}: v2' routed to echo-v2, no header routed to echo (L7 handled by the waypoint)"
  else
    record 5 FAIL "${why# } If requests reach echo but ignore the header, the waypoint is not in the path: check 'kubectl -n ${NS} get httproute echo-header-route -o yaml' status, the waypoint logs, and (UNVERIFIED hypothesis) whether Dataplane V2 socket LB rewrote the Service VIP to a pod IP before ztunnel saw it, which would skip service-attached waypoints."
  fi
}

cmd_test() {
  preflight
  istioctl_check
  kc get namespace "$NS" >/dev/null 2>&1 || die "namespace ${NS} not found: run '$0 deploy' first"
  log "Istio ${ISTIO_VERSION}; images ${CLIENT_IMAGE}, ${ECHO_IMAGE}"
  kc -n "$NS" get pods -o wide || true

  reset_baseline
  check_1
  check_2
  check_3
  check_4
  check_5

  if [ "$FAILED" = 1 ]; then
    local zt
    zt="$(echo_ztunnel || true)"
    if [ -n "$zt" ]; then
      printf '\n--- diagnostics: last 40 lines of %s (echo node) ---\n' "$zt"
      kc -n "$ISTIO_NS" logs "$zt" --tail=40 2>/dev/null || true
    fi
  fi

  printf '\n===== SUMMARY (Istio %s) =====\n%s' "$ISTIO_VERSION" "$RESULTS"
  if [ "$FAILED" = 1 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
  fi
  printf 'RESULT: PASS\n'
}

# ---------------------------------------------------------------------------
# cleanup (the only destructive subcommand)
# ---------------------------------------------------------------------------
cmd_cleanup() {
  preflight
  need helm
  if [ "${1:-}" != "--yes" ] && [ "${SMOKE_ASSUME_YES:-0}" != "1" ]; then
    local answer=""
    printf "This deletes namespace %s and uninstalls ztunnel, istio-cni, istiod, istio-base from %s on context %s.\nType 'yes' to continue: " \
      "$NS" "$ISTIO_NS" "$(kubectl config current-context)"
    read -r answer || true
    [ "$answer" = "yes" ] || die "aborted"
  fi

  log "deleting namespace ${NS} (timeout ${NS_DELETE_TIMEOUT})"
  kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout="$NS_DELETE_TIMEOUT"

  local rel
  for rel in ztunnel istio-cni istiod istio-base; do
    if helm status "$rel" -n "$ISTIO_NS" >/dev/null 2>&1; then
      log "helm uninstall ${rel}"
      helm uninstall "$rel" -n "$ISTIO_NS" --wait --timeout "$HELM_TIMEOUT"
    else
      log "helm release ${rel} not installed, skipping"
    fi
  done
  log "cleanup done. Left in place: namespace ${ISTIO_NS}, its ResourceQuota, and any Istio CRDs Helm does not remove. 'make down' removes everything."
}

usage() {
  cat >&2 <<EOF
usage: $0 {install|deploy|test|cleanup [--yes]}
  install  Helm-install Istio ${ISTIO_VERSION} ambient (base, istiod, istio-cni, ztunnel) for GKE
  deploy   create namespace ${NS} (ambient) with client, client-other, echo, echo-v2
  test     run checks 1-5; exit 0 only if all PASS
  cleanup  DELETE namespace ${NS} and uninstall the Istio releases (asks first)
Prereq: ${GET_CREDS}
EOF
}

main() {
  case "${1:-}" in
    install) cmd_install ;;
    deploy) cmd_deploy ;;
    test) cmd_test ;;
    cleanup) shift; cmd_cleanup "${1:-}" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
