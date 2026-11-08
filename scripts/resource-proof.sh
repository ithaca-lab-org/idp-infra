#!/usr/bin/env bash
# Proof of ADR 0010 (tenant resources and grants) against the REAL resource broker and the REAL
# Google APIs. Run by a human from a laptop with gcloud (project set, allowed to read the project,
# buckets and org policies and to create and delete the proof buckets) and kubectl (pointed at the
# idp cluster, cluster admin). Not part of `make up` or CI. Docs: docs/tenant-resources.md, "Proof".
#
# What it does (and undoes):
#   1. preflight: kubectl context, CRDs, Deployment idp-system/idp-broker Available with
#      BROKER_ENABLED=true, gcloud project, custom role idpBrokerBuckets, the conditional project
#      binding of idp-broker@, org policies storage.publicAccessPrevention and
#      storage.uniformBucketLevelAccess effective enforce=true, no leftovers of an earlier run.
#   2. TeamNamespaces rproof-a and rproof-b; WorkloadIdentities wl-a, wl-other (rproof-a), wl-b (rproof-b).
#   3. BucketClaim data in rproof-a: bucket exists with name, labels, public access prevention,
#      uniform access, location.
#   4. ResourceGrant wl-a-data (writer): the bucket policy gains exactly one binding.
#   5. pods (curl with the metadata-server token): wl-a writes and reads (200), wl-other and wl-b get 403.
#   6. reader vs writer, and revoke: grant wl-other-data (reader): read 200, write 403; deleting it: 403 again.
#   7. broker limits (PROOF_BROKER_LIMITS=on): as idp-broker@ via impersonation: role limit, public
#      grant, outside member (observed only), non-idp bucket create, Terraform state bucket (read only).
#   8. release: deleting claim data that holds an object orphans the bucket (CR gone, label
#      idp-orphaned=true, no principal binding left); deleting an empty claim deletes its bucket.
#   9. cleanup (EXIT trap): CRs, TeamNamespaces, the tokenCreator grant this run added, and ONLY buckets
#      this run produced (name idp-rproof-(a|b)-*, owner label rproof-a|b, claim UID recorded here).
# A PASS/FAIL line per proof and a summary table; exit non-zero on any FAIL.
#
# Environment: PROOF_BROKER_LIMITS=on|off (default on)   PROOF_YES=1 skips the confirmation
#   PROOF_DRY_RUN=1 prints what it would do and exits before creating anything
#   PROOF_READY_TIMEOUT (TeamNamespace, WorkloadIdentity, claim, grant Ready; default 180 s)
#   PROOF_PROP_TIMEOUT (IAM propagation for pod expectations; default 300 s)
#   PROOF_COND_TIMEOUT (conditional bindings, impersonation; default 300 s)
#   PROOF_DENY_TIMEOUT (a 403 that is expected from the start; default 60 s)
#   PROOF_DELETE_TIMEOUT (namespace and claim deletion; default 300 s)   PROOF_POLL (default 5 s)
# Tokens never reach stdout, argv or files: pods keep them in a shell variable; only HTTP status
# codes, seconds and random markers are printed. Bash 3.2 compatible (macOS). Needs jq.
set -euo pipefail
set +x # never trace

NS_A="rproof-a"
NS_B="rproof-b"
MARK_KEY="idp.ithaca-idp.com/resource-proof"
MARK_JSONPATH='{.metadata.labels.idp\.ithaca-idp\.com/resource-proof}'
REGION="us-central1"
# Pinned: curlimages/curl 8.11.1 (Alpine based, has sh, sed, date, curl; runs as uid 100). Bump deliberately.
IMAGE="curlimages/curl:8.11.1"
LIMITS="${PROOF_BROKER_LIMITS:-on}"
YES="${PROOF_YES:-0}"
DRY="${PROOF_DRY_RUN:-0}"
READY_TIMEOUT="${PROOF_READY_TIMEOUT:-180}"
PROP_TIMEOUT="${PROOF_PROP_TIMEOUT:-300}"
COND_TIMEOUT="${PROOF_COND_TIMEOUT:-300}"
DENY_TIMEOUT="${PROOF_DENY_TIMEOUT:-60}"
DELETE_TIMEOUT="${PROOF_DELETE_TIMEOUT:-300}"
POLL="${PROOF_POLL:-5}"
ME="./scripts/resource-proof.sh"
RUNBOOK="docs/tenant-resources.md"

K_TNS="teamnamespaces.idp.ithaca-idp.com"
K_CLAIM="bucketclaims.idp.ithaca-idp.com"
K_GRANT="resourcegrants.idp.ithaca-idp.com"
K_WID="workloadidentities.idp.ithaca-idp.com"

START=$SECONDS
RESULTS=""
FAILED=0
FAILED_CLEAN=""
STARTED=""        # set once anything was created: enables the cleanup
CREATED_A=""
CREATED_B=""
UIDS=""           # claim UIDs this run created (space separated)
TC_MEMBER=""      # member given tokenCreator on the broker service account by this run
EXTRA_BINDINGS="" # "bucket|role|member" lines this run may have left on a proof bucket
EXTRA_BUCKETS=""  # non-idp bucket names this run created by mistake (only if the broker limit failed)
tmp=""
PROJECT=""
PNUM=""
ACCOUNT=""
ME_MEMBER=""
BUCKET_DATA=""
BUCKET_EMPTY=""
MARKER=""

elapsed() { printf '%ss' "$((SECONDS - START))"; }
step() { printf '\n==> %s  (t+%s)\n' "$*" "$(elapsed)"; }
info() { printf '    %s\n' "$*"; }
record() { RESULTS="${RESULTS}$(printf '%-5s %s' "$1" "$2")"$'\n'; }
ppass() { record PASS "$*"; printf '    PASS  %s\n' "$*"; }
pskip() { record SKIP "$*"; printf '    SKIP  %s\n' "$*"; }
pobs() { record OBS "$*"; printf '    OBSERVED  %s\n' "$*"; }
pfail() { record FAIL "$*"; FAILED=1; printf '    FAIL  %s\n' "$*" >&2; }
die() { record FAIL "setup: $*"; FAILED=1; printf '    FAIL  setup: %s\n' "$*" >&2; exit 1; }
oneline() { tr '\n' ' ' <"$1" 2>/dev/null | cut -c1-"${2:-200}"; }
first_err() { oneline "$tmp/err" 200; }
remaining() {
  local r=$(($1 - SECONDS))
  [ "$r" -ge 1 ] || r=1
  echo "$r"
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

case "$LIMITS" in on | off) ;; *) printf 'resource-proof: PROOF_BROKER_LIMITS must be on or off\n' >&2; exit 64 ;; esac
case "${1:-}" in
  "") ;;
  -h | --help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
  *) printf 'Usage: %s   (see the header; configuration is by PROOF_* environment variables)\n' "$ME" >&2; exit 64 ;;
esac

# --- dry run (needs no cluster) ------------------------------------------------------------------
if [ "$DRY" = "1" ]; then
  P="$(gcloud config get-value project 2>/dev/null || echo '<project>')"
  printf 'resource-proof dry run: nothing is created. A real run WOULD:\n'
  printf '  1 preflight (read-only): kubectl context, CRDs bucketclaims/resourcegrants, Deployment idp-system/idp-broker\n'
  printf '    Available with BROKER_ENABLED=true, role idpBrokerBuckets, project binding of idp-broker@%s, org policies\n' "$P"
  printf '    storage.publicAccessPrevention and storage.uniformBucketLevelAccess enforced, no leftover %s/%s or buckets idp-rproof-*\n' "$NS_A" "$NS_B"
  printf '  2 create TeamNamespaces %s and %s; WorkloadIdentities wl-a, wl-other (%s), wl-b (%s)\n' "$NS_A" "$NS_B" "$NS_A" "$NS_B"
  printf '  3 create BucketClaim data in %s (a bucket idp-%s-data-<8 hex> in project %s, %s)\n' "$NS_A" "$NS_A" "$P" "$REGION"
  printf '  4 create ResourceGrant wl-a-data (writer); 5 run 4 pods (%s): wl-a write+read, wl-other read, wl-b read\n' "$IMAGE"
  printf '  6 grant wl-other-data (reader), pods read+write, delete the grant, pod read\n'
  if [ "$LIMITS" = on ]; then
    printf '  7 impersonate idp-broker@%s (tokenCreator for you on that service account ONLY if impersonation fails; removed at the end):\n' "$P"
    printf '    add objectViewer, add storage.admin (must be denied), remove objectViewer, add allUsers (must be denied), add an outside user\n'
    printf '    (observed), create a bucket without the idp- prefix (must be denied), read IAM of the tfstate bucket (must be denied)\n'
  else
    printf '  7 skipped (PROOF_BROKER_LIMITS=off)\n'
  fi
  printf '  8 delete claim data (holds an object): expect orphan; create and delete claim empty: expect the bucket gone; re-create it\n'
  printf '  9 cleanup: CRs, TeamNamespaces, tokenCreator grant, and only buckets idp-rproof-(a|b)-* labelled for these namespaces with claim UIDs of this run\n'
  exit 0
fi

# --- tools ---------------------------------------------------------------------------------------
for t in kubectl gcloud jq od awk tr; do
  command -v "$t" >/dev/null 2>&1 || { printf 'resource-proof: %s not found on PATH\n' "$t" >&2; exit 1; }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  printf 'resource-proof: neither sha256sum nor shasum found on PATH\n' >&2
  exit 1
fi
umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resource-proof.XXXXXX")"
: >"$tmp/err"

# --- helpers: cloud ------------------------------------------------------------------------------
# list_buckets_json <file>: every bucket of the project as a JSON array (raw API form, with labels).
list_buckets_json() {
  gcloud storage buckets list --project="$PROJECT" --raw --format=json >"$1" 2>"$tmp/err" && jq -e 'type == "array"' "$1" >/dev/null 2>&1
}
# bucket_json <name> <file>: describe one bucket (raw API form).
bucket_json() { gcloud storage buckets describe "gs://$1" --project="$PROJECT" --raw --format=json >"$2" 2>"$tmp/err"; }
# policy_json <name> <file> [extra gcloud flags]: bucket IAM policy.
policy_json() {
  local b="$1" f="$2"
  shift 2
  gcloud storage buckets get-iam-policy "gs://$b" --project="$PROJECT" --format=json "$@" >"$f" 2>"$tmp/err"
}
PAIRS='[.bindings[]? | .role as $r | .members[]? | [$r, .]] | sort'
pairs_of() { jq -c "$PAIRS" "$1"; }
# member <namespace> <workload>
member() {
  printf 'principal://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s.svc.id.goog/subject/ns/%s/sa/%s' \
    "$PNUM" "$PROJECT" "$1" "$2"
}
# principal_count <policy file> <namespace>: members of this namespace's principals in the policy
principal_count() {
  jq -r --arg p "$(member "$1" '')" '[.bindings[]?.members[]? | select(startswith($p))] | length' "$2"
}
has_binding() { # has_binding <policy file> <role> <member>
  jq -e --arg r "$2" --arg m "$3" 'any(.bindings[]?; .role == $r and any(.members[]?; . == $m))' "$1" >/dev/null 2>&1
}
# verdict <rc> <err file>: allowed | denied | retry | error. Denied needs a non-zero exit AND text showing
# 403, PERMISSION_DENIED, "does not have" or an org-policy violation. 412, precondition, etag and condition
# conflicts are "retry" (the caller retries a bounded number of times, then reports it inconclusive);
# everything else (transport, syntax) is "error". Neither can ever pass as a denial.
verdict() {
  if [ "$1" -eq 0 ]; then
    echo allowed
  elif grep -qiE '403|PERMISSION_DENIED|does not have|organization policy|org policy|violat|constraint|public access prevention|publicAccessPrevention' "$2" 2>/dev/null; then
    echo denied
  elif grep -qiE '412|precondition|etag|conflict|condition' "$2" 2>/dev/null; then
    echo retry
  else
    echo error
  fi
}
PV=""
# probe <cmd...>: runs the command (up to 4 times while the answer is "retry"); sets PV to
# allowed | denied | error and leaves the last stderr in $tmp/err.
probe() {
  local i=0 rc
  while :; do
    if "$@" >"$tmp/out" 2>"$tmp/err"; then rc=0; else rc=$?; fi
    PV="$(verdict "$rc" "$tmp/err")"
    { [ "$PV" = retry ] && [ "$i" -lt 3 ]; } || break
    i=$((i + 1))
    sleep 5
  done
  [ "$PV" != retry ] || PV=error
}
A_RC=0
A_SECS=0
# attempt <max-seconds> <cmd...>: retries every 10 s until success or time is up; sets A_RC, A_SECS.
attempt() {
  local max="$1" t0=$SECONDS
  shift
  while :; do
    if "$@" >"$tmp/out" 2>"$tmp/err"; then A_RC=0; else A_RC=$?; fi
    A_SECS=$((SECONDS - t0))
    [ "$A_RC" -ne 0 ] || break
    [ "$A_SECS" -lt "$max" ] || break
    sleep 10
  done
}

# --- helpers: cluster ----------------------------------------------------------------------------
tns_state() { # tns_state <name>: ours | foreign | terminating | absent | error
  local t ns
  t="$(kubectl get teamnamespace "$1" --ignore-not-found -o jsonpath="{.metadata.name}|$MARK_JSONPATH" 2>"$tmp/err")" || { echo error; return 0; }
  ns="$(kubectl get namespace "$1" --ignore-not-found -o jsonpath='{.metadata.name}|{.status.phase}' 2>"$tmp/err")" || { echo error; return 0; }
  if [ "$t" = "$1|true" ]; then echo ours
  elif [ -n "$t" ]; then echo foreign
  elif [ "$ns" = "$1|Terminating" ]; then echo terminating
  elif [ -n "$ns" ]; then echo foreign
  else echo absent
  fi
}
delete_tns_if_ours() { # deletes the TeamNamespace only if it carries our label; waits for it and its namespace
  local st deadline
  st="$(tns_state "$1")"
  case "$st" in
    absent) return 0 ;;
    foreign | error) info "not touching $1 ($st)"; return 1 ;;
    ours) kubectl delete teamnamespace "$1" --wait=false >/dev/null 2>&1 || return 1 ;;
  esac
  deadline=$((SECONDS + DELETE_TIMEOUT))
  kubectl wait --for=delete "teamnamespace/$1" --timeout="$(remaining "$deadline")s" >/dev/null 2>&1 || return 1
  kubectl wait --for=delete "namespace/$1" --timeout="$(remaining "$deadline")s" >/dev/null 2>&1 || return 1
}
tns_yaml() { # same shape as vault-proof.sh
  printf 'apiVersion: idp.ithaca-idp.com/v1alpha1\nkind: TeamNamespace\nmetadata:\n  name: %s\n  labels:\n    %s: "true"\nspec:\n  businessUnit: verify-bu\n  owner: verify@example.com\n  size: small\n  orderId: %s\n' \
    "$1" "$MARK_KEY" "$2"
}
wid_yaml() { printf 'apiVersion: idp.ithaca-idp.com/v1alpha1\nkind: WorkloadIdentity\nmetadata:\n  name: %s\n  namespace: %s\nspec: {}\n' "$1" "$2"; }
claim_yaml() { printf 'apiVersion: idp.ithaca-idp.com/v1alpha1\nkind: BucketClaim\nmetadata:\n  name: %s\n  namespace: %s\nspec: {}\n' "$1" "$2"; }
grant_yaml() { # <name> <ns> <workload> <resource> <access>
  printf 'apiVersion: idp.ithaca-idp.com/v1alpha1\nkind: ResourceGrant\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  workload: %s\n  resource: %s\n  access: %s\n' \
    "$1" "$2" "$3" "$4" "$5"
}
cond_status() { kubectl -n "$1" get "$2" "$3" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null || true; }
cond_reason() { kubectl -n "$1" get "$2" "$3" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].reason}" 2>/dev/null || true; }
# wait_cond <ns> <kind> <name> <condition> <timeout>: 0 once the condition is True
wait_cond() {
  local deadline=$((SECONDS + $5))
  while :; do
    [ "$(cond_status "$1" "$2" "$3" "$4")" = True ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}
# wait_gone <ns> <kind> <name> <timeout>
wait_gone() {
  local deadline=$((SECONDS + $4))
  while :; do
    [ -z "$(kubectl -n "$1" get "$2" "$3" --ignore-not-found -o name 2>/dev/null || true)" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}
create_cr() { # create_cr <yaml-producing-function-and-args...> : pipes to kubectl create
  "$@" | kubectl create -f - >/dev/null 2>"$tmp/err"
}
claim_uid() { kubectl -n "$1" get "$K_CLAIM" "$2" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
# make_claim <ns> <name>: creates the claim, records its UID at once (the cleanup deletes by UID).
make_claim() {
  local u
  create_cr claim_yaml "$2" "$1" || return 1
  u="$(claim_uid "$1" "$2")"
  [ -n "$u" ] || return 1
  UIDS="$UIDS $u"
  return 0
}

# --- pods ----------------------------------------------------------------------------------------
# Runs in the pod. Env: OP (write|read) BUCKET OBJ EXPECT (HTTP code) DEADLINE (seconds) MARKER.
# Retries until the HTTP code equals EXPECT or the deadline passes. One RESULT line; the token only
# lives in a shell variable. The HTTP code alone decides (a transport error is 000, no token is NOTOKEN).
POD_SH='set -u
start=$(date +%s)
code=000
match=na
reason=""
while :; do
  tok=$(curl -s -m 10 -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | sed -n "s/.*\"access_token\" *: *\"\([^\"]*\)\".*/\1/p")
  match=na
  if [ -z "$tok" ]; then
    code=NOTOKEN
    reason="no-token-from-metadata-server"
  else
    case "$OP" in
      write) code=$(curl -s -m 20 -o /tmp/b -w "%{http_code}" -X POST -H "Authorization: Bearer $tok" -H "Content-Type: text/plain" --data "$MARKER" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$OBJ") ;;
      read) code=$(curl -s -m 20 -o /tmp/b -w "%{http_code}" -H "Authorization: Bearer $tok" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/$OBJ?alt=media") ;;
    esac
    if [ "$code" = 200 ] && [ "$OP" = read ]; then
      match=no
      [ "$(cat /tmp/b)" = "$MARKER" ] && match=yes
    fi
    reason=$(sed -n "s/.*\"reason\" *: *\"\([^\"]*\)\".*/\1/p" /tmp/b | head -n 1)
  fi
  tok=""
  el=$(( $(date +%s) - start ))
  [ "$code" = "$EXPECT" ] && { [ "$match" != no ] || [ "$el" -ge "$DEADLINE" ]; } && break
  [ "$el" -ge "$DEADLINE" ] && break
  sleep 10
done
echo "RESULT code=$code elapsed=$el match=$match reason=${reason:-none}"'

POD_CODE=""
POD_SECS=""
POD_MATCH=""
POD_REASON=""
# run_pod <name> <namespace> <serviceaccount> <op> <bucket> <object> <expect> <deadline>
run_pod() {
  local name="$1" ns="$2" sa="$3" op="$4" bucket="$5" obj="$6" expect="$7" deadline="$8" phase="" t0=$SECONDS line="" ov
  POD_CODE="n/a"
  POD_SECS="n/a"
  POD_MATCH="na"
  POD_REASON="pod did not run"
  ov="$(printf '{"spec":{"serviceAccountName":"%s","securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"%s","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' "$sa" "$name")"
  # First with a hardened pod spec (strategic merge by container name); if this kubectl cannot,
  # again with only the ServiceAccount override like the spike did.
  if ! kubectl -n "$ns" run "$name" --image="$IMAGE" --restart=Never --labels="$MARK_KEY=true" \
    --override-type=strategic --overrides="$ov" \
    --env="OP=$op" --env="BUCKET=$bucket" --env="OBJ=$obj" --env="EXPECT=$expect" --env="DEADLINE=$deadline" --env="MARKER=$MARKER" \
    --command -- sh -c "$POD_SH" >/dev/null 2>"$tmp/err"; then
    if ! kubectl -n "$ns" run "$name" --image="$IMAGE" --restart=Never --labels="$MARK_KEY=true" \
      --overrides="{\"spec\":{\"serviceAccountName\":\"$sa\"}}" \
      --env="OP=$op" --env="BUCKET=$bucket" --env="OBJ=$obj" --env="EXPECT=$expect" --env="DEADLINE=$deadline" --env="MARKER=$MARKER" \
      --command -- sh -c "$POD_SH" >/dev/null 2>"$tmp/err"; then
      POD_REASON="kubectl run failed: $(first_err)"
      return 0
    fi
  fi
  while [ $((SECONDS - t0)) -lt $((deadline + 240)) ]; do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 5
  done
  line="$(kubectl -n "$ns" logs "$name" 2>/dev/null | grep '^RESULT ' | tail -n 1 || true)"
  kubectl -n "$ns" delete pod "$name" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  if [ -z "$line" ]; then
    POD_REASON="no RESULT line (pod phase: ${phase:-unknown}; image pull, scheduling or a NetworkPolicy blocking the metadata server?)"
    return 0
  fi
  POD_CODE="$(printf '%s' "$line" | sed -n 's/.*code=\([^ ]*\).*/\1/p')"
  POD_SECS="$(printf '%s' "$line" | sed -n 's/.*elapsed=\([^ ]*\).*/\1/p')"
  POD_MATCH="$(printf '%s' "$line" | sed -n 's/.*match=\([^ ]*\).*/\1/p')"
  POD_REASON="$(printf '%s' "$line" | sed -n 's/.*reason=\(.*\)$/\1/p')"
}
# pod_case <id> <description> <expect> <deadline> <pod> <ns> <sa> <op> <bucket> <object>
pod_case() {
  local id="$1" desc="$2" expect="$3" deadline="$4"
  run_pod "$5" "$6" "$7" "$8" "$9" "${10}" "$expect" "$deadline"
  info "$id: HTTP $POD_CODE after ${POD_SECS}s (expected $expect) reason=$POD_REASON"
  if [ "$POD_CODE" = "$expect" ] && { [ "$expect" != 200 ] || [ "$8" != read ] || [ "$POD_MATCH" = yes ]; }; then
    ppass "$id $desc: HTTP $POD_CODE after ${POD_SECS}s"
  elif [ "$POD_CODE" = "$expect" ]; then
    pfail "$id $desc: HTTP 200 but the object differs from the marker written"
  else
    pfail "$id $desc: HTTP $POD_CODE after ${POD_SECS}s, expected $expect (reason=$POD_REASON)"
  fi
}

# --- cleanup (EXIT trap) -------------------------------------------------------------------------
clean() { # clean <manual fix> <cmd...>: a failing step is collected, never stops the cleanup
  local manual="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then FAILED_CLEAN="${FAILED_CLEAN}    ${manual}"$'\n'; fi
  return 0
}
delete_run_buckets() {
  local uids names b
  list_buckets_json "$tmp/all.json" || return 1
  uids="$(printf '%s\n' $UIDS | jq -R 'select(length > 0)' | jq -sc .)"
  # ONLY: name idp-rproof-(a|b)-*, label idp-namespace rproof-a|rproof-b, label idp-claim-uid among the UIDs of this run.
  names="$(jq -r --argjson uids "$uids" '.[] | select((.name | test("^idp-rproof-(a|b)-")) and (((.labels // {})["idp-namespace"]) as $n | ($n == "rproof-a" or $n == "rproof-b")) and (((.labels // {})["idp-claim-uid"]) as $u | ($u != null and ($uids | index($u)) != null))) | .name' "$tmp/all.json")" || return 1
  for b in $names; do
    case "$b" in idp-rproof-a-* | idp-rproof-b-*) ;; *) continue ;; esac
    clean "gcloud storage rm --recursive gs://$b --project=$PROJECT" gcloud storage rm --recursive "gs://$b" --project="$PROJECT"
  done
  return 0
}
cleanup() {
  local rc=$? n line b r m
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  [ "$rc" = 0 ] || FAILED=1
  if [ -n "$STARTED" ]; then
    step "cleanup (only what this run created)"
    # First: the tokenCreator grant must not outlive a hurried exit (Ctrl-C is ignored from here on).
    if [ -n "$TC_MEMBER" ]; then
      if gcloud iam service-accounts get-iam-policy "$BROKER_SA" --project="$PROJECT" --format=json >"$tmp/sa.json" 2>/dev/null \
        && ! jq -e --arg m "$TC_MEMBER" 'any(.bindings[]?; .role == "roles/iam.serviceAccountTokenCreator" and any(.members[]?; . == $m))' "$tmp/sa.json" >/dev/null 2>&1; then
        info "no tokenCreator grant for $TC_MEMBER on $BROKER_SA to remove"
      else
        clean "gcloud iam service-accounts remove-iam-policy-binding $BROKER_SA --member=$TC_MEMBER --role=roles/iam.serviceAccountTokenCreator --project=$PROJECT" \
          gcloud iam service-accounts remove-iam-policy-binding "$BROKER_SA" \
          --member="$TC_MEMBER" --role=roles/iam.serviceAccountTokenCreator --project="$PROJECT"
        info "tokenCreator grant for $TC_MEMBER on $BROKER_SA removal attempted"
      fi
    fi
    clean "kubectl -n $NS_A delete $K_GRANT,$K_CLAIM,$K_WID --all" kubectl -n "$NS_A" delete "$K_GRANT,$K_CLAIM,$K_WID" --all --ignore-not-found --wait=false
    clean "kubectl -n $NS_B delete $K_GRANT,$K_CLAIM,$K_WID --all" kubectl -n "$NS_B" delete "$K_GRANT,$K_CLAIM,$K_WID" --all --ignore-not-found --wait=false
    for n in "$NS_A" "$NS_B"; do
      if { [ "$n" = "$NS_A" ] && [ -n "$CREATED_A" ]; } || { [ "$n" = "$NS_B" ] && [ -n "$CREATED_B" ]; }; then
        info "deleting TeamNamespace $n (up to ${DELETE_TIMEOUT}s, the operator purges it and the broker releases its claims)"
        clean "kubectl delete teamnamespace $n  (then check: kubectl get teamnamespace,namespace $n)" delete_tns_if_ours "$n"
      fi
    done
    # Bindings a failed limit check may have left (removed as the human; the buckets go next anyway).
    while IFS='|' read -r b r m; do
      [ -n "$b" ] || continue
      # only if the binding is still there (7c and 7e remove theirs already; a missing bucket needs nothing)
      policy_json "$b" "$tmp/polc.json" 2>/dev/null || continue
      has_binding "$tmp/polc.json" "$r" "$m" || continue
      clean "gcloud storage buckets remove-iam-policy-binding gs://$b --member='$m' --role=$r --project=$PROJECT" \
        gcloud storage buckets remove-iam-policy-binding "gs://$b" --member="$m" --role="$r" --project="$PROJECT"
    done <<EOF
$EXTRA_BINDINGS
EOF
    for b in $EXTRA_BUCKETS; do
      case "$b" in rproof-noprefix-*) clean "gcloud storage rm --recursive gs://$b --project=$PROJECT" gcloud storage rm --recursive "gs://$b" --project="$PROJECT" ;; esac
    done
    if [ -n "$PROJECT" ] && ! delete_run_buckets; then
      FAILED_CLEAN="${FAILED_CLEAN}    could not list buckets: find them with: gcloud storage buckets list --project=$PROJECT --filter='name~^idp-rproof-' --format='value(name)', then gcloud storage rm --recursive gs://<name>"$'\n'
    fi
    if [ -n "$PROJECT" ] && list_buckets_json "$tmp/all2.json"; then
      for b in $(jq -r '.[] | select(.name | test("^idp-rproof-")) | .name' "$tmp/all2.json"); do
        FAILED_CLEAN="${FAILED_CLEAN}    bucket gs://$b is still there (not recorded by this run or not deleted): check it, then gcloud storage rm --recursive gs://$b --project=$PROJECT"$'\n'
      done
    fi
    if [ -n "$FAILED_CLEAN" ]; then
      printf '\nresource-proof: CLEANUP INCOMPLETE. Fix by hand:\n%s' "$FAILED_CLEAN" >&2
      record FAIL "cleanup incomplete (commands printed above)"
      FAILED=1
    else
      info "cleanup complete"
    fi
  fi
  [ -z "$tmp" ] || rm -rf "$tmp"
  printf '\n===== resource-proof.sh summary (took %s) =====\n' "$(elapsed)"
  printf '%s' "$RESULTS"
  if [ "$FAILED" = 0 ]; then
    printf 'RESULT: all proofs passed\n'
    exit 0
  fi
  printf 'RESULT: FAILED (see the FAIL lines above; %s, "Proof")\n' "$RUNBOOK" >&2
  exit 1
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- 1. preflight (read-only) --------------------------------------------------------------------
step "1. preflight (read-only)"
ctx="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$ctx" ] || die "kubectl has no current context"
kubectl get --raw /version >/dev/null 2>"$tmp/err" || die "kubectl context '$ctx' is not reachable: $(first_err)"
info "kubectl context: $ctx"
kubectl get crd "$K_CLAIM" "$K_GRANT" "$K_WID" "$K_TNS" >/dev/null 2>"$tmp/err" \
  || die "a CRD (bucketclaims, resourcegrants, workloadidentities, teamnamespaces) is missing: $(first_err)"
avail="$(kubectl -n idp-system get deployment idp-broker -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
[ "$avail" = True ] || die "Deployment idp-system/idp-broker is not Available (got '${avail:-missing}')"
benabled="$(kubectl -n idp-system get deployment idp-broker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BROKER_ENABLED")].value}' 2>/dev/null || true)"
[ "$benabled" = true ] || die "the broker ships disabled: BROKER_ENABLED is '${benabled:-unset}', not \"true\". Flip it in idp-gitops workloads/idp-operator/idp-broker.yaml and let Argo CD sync"
info "idp-broker is Available with BROKER_ENABLED=true"

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
{ [ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ]; } || die "no gcloud project set (gcloud config set project ...)"
PNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
[ -n "$PNUM" ] || die "cannot describe project $PROJECT (authenticated?)"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
{ [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "(unset)" ]; } || die "no gcloud account (gcloud auth login)"
case "$ACCOUNT" in
  *.gserviceaccount.com) ME_MEMBER="serviceAccount:$ACCOUNT" ;;
  *) ME_MEMBER="user:$ACCOUNT" ;;
esac
BROKER_SA="idp-broker@$PROJECT.iam.gserviceaccount.com"
info "project $PROJECT ($PNUM), account $ACCOUNT"

gcloud iam roles describe idpBrokerBuckets --project="$PROJECT" >/dev/null 2>"$tmp/err" \
  || die "custom role idpBrokerBuckets does not exist ($(first_err)); $RUNBOOK, \"Apply order\""
gcloud projects get-iam-policy "$PROJECT" --format=json >"$tmp/proj.json" 2>"$tmp/err" || die "cannot read the project IAM policy: $(first_err)"
jq -e --arg r "projects/$PROJECT/roles/idpBrokerBuckets" --arg m "serviceAccount:$BROKER_SA" \
  'any(.bindings[]?; .role == $r and (.condition != null) and any(.members[]?; . == $m))' "$tmp/proj.json" >/dev/null 2>&1 \
  || die "no conditional project binding of the custom role for $BROKER_SA ($RUNBOOK, \"Verify\")"
info "role idpBrokerBuckets and the conditional binding of $BROKER_SA exist"
for c in storage.publicAccessPrevention storage.uniformBucketLevelAccess; do
  gcloud org-policies describe "$c" --project="$PROJECT" --effective --format=json >"$tmp/org.json" 2>"$tmp/err" \
    || die "cannot read the effective org policy $c ($(first_err)): the guardrails of $RUNBOOK (\"Guardrails a human must set\") are not in place"
  jq -e 'any(.spec.rules[]?; .enforce == true)' "$tmp/org.json" >/dev/null 2>&1 \
    || die "org policy $c is not effectively enforced: set the guardrails first, $RUNBOOK (\"Guardrails a human must set before RESOURCES_ENABLED\", scripts/set-tenant-org-policies.sh)"
done
info "org policies storage.publicAccessPrevention and storage.uniformBucketLevelAccess are enforced"

left=""
for n in "$NS_A" "$NS_B"; do
  st="$(tns_state "$n")"
  case "$st" in
    absent) ;;
    error) die "could not check whether $n exists: $(first_err)" ;;
    *) left="$left TeamNamespace/namespace:$n($st)" ;;
  esac
done
list_buckets_json "$tmp/all.json" || die "cannot list the buckets of $PROJECT: $(first_err)"
lb="$(jq -r '.[] | select((.name | test("^idp-rproof-(a|b)-")) or (((.labels // {})["idp-namespace"]) as $n | ($n == "rproof-a" or $n == "rproof-b"))) | .name' "$tmp/all.json")"
for b in $lb; do left="$left bucket:$b"; done
if [ -n "$left" ]; then
  printf '    leftovers of an earlier run:%s\n' "$left" >&2
  printf '    clean them first (this script never touches objects it did not create):\n' >&2
  printf '      kubectl delete teamnamespace %s %s   (the operator and broker release the claims)\n' "$NS_A" "$NS_B" >&2
  for b in $lb; do printf '      gcloud storage rm --recursive gs://%s --project=%s   (after checking it is a proof bucket)\n' "$b" "$PROJECT" >&2; done
  die "refusing to run with leftovers"
fi
ppass "1 preflight: broker enabled, role and binding present, guardrails enforced, no leftovers"

step "confirmation"
cat <<EOF
    WARNING: this creates in project $PROJECT and in the cluster of kubectl context '$ctx':
    TeamNamespaces $NS_A and $NS_B, WorkloadIdentities, BucketClaims, ResourceGrants, buckets
    idp-rproof-*, short-lived pods, and (limits on) a tokenCreator grant for you on $BROKER_SA only
    if impersonation fails. All of it is removed again on exit. Takes about 15 to 30 minutes.
EOF
if [ "$YES" != "1" ]; then
  [ -t 0 ] || die "not a terminal; set PROOF_YES=1 to confirm non-interactively"
  printf '    Type yes to continue: '
  read -r ans
  [ "$ans" = "yes" ] || die "aborted"
fi
MARKER="rproof-$(rand_hex 12)"
RAND="$(rand_hex 3)"

# --- 2. namespaces and workload identities ---------------------------------------------------------
step "2. TeamNamespaces $NS_A and $NS_B, WorkloadIdentities (waiting up to ${READY_TIMEOUT}s each)"
STARTED=1
for n in "$NS_A" "$NS_B"; do
  if [ "$n" = "$NS_A" ]; then CREATED_A=1; else CREATED_B=1; fi # before create: the cleanup checks the label
  order="ORD-0000-$(printf '%06d' "$(($(od -An -N4 -tu4 /dev/urandom | tr -d ' \n') % 1000000))")"
  create_cr tns_yaml "$n" "$order" || die "could not create TeamNamespace $n: $(first_err)"
done
for n in "$NS_A" "$NS_B"; do
  deadline=$((SECONDS + READY_TIMEOUT))
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "teamnamespace/$n" --timeout="$(remaining "$deadline")s" >/dev/null 2>&1 \
    || die "TeamNamespace $n did not become Ready (kubectl get teamnamespace $n -o yaml)"
done
create_cr wid_yaml wl-a "$NS_A" || die "could not create WorkloadIdentity wl-a: $(first_err)"
create_cr wid_yaml wl-other "$NS_A" || die "could not create WorkloadIdentity wl-other: $(first_err)"
create_cr wid_yaml wl-b "$NS_B" || die "could not create WorkloadIdentity wl-b: $(first_err)"
for w in "$NS_A/wl-a" "$NS_A/wl-other" "$NS_B/wl-b"; do
  wait_cond "${w%/*}" "$K_WID" "${w#*/}" Synced "$READY_TIMEOUT" \
    || die "WorkloadIdentity $w is not Synced (reason: $(cond_reason "${w%/*}" "$K_WID" "${w#*/}" Synced))"
done
ppass "2 TeamNamespaces Ready; WorkloadIdentities wl-a, wl-other, wl-b Synced"

# --- 3. bucket claim -------------------------------------------------------------------------------
step "3. BucketClaim data in $NS_A (waiting up to ${READY_TIMEOUT}s)"
make_claim "$NS_A" data || die "could not create BucketClaim data (or read its UID): $(first_err)"
UID_DATA="$(claim_uid "$NS_A" data)"
wait_cond "$NS_A" "$K_CLAIM" data Ready "$READY_TIMEOUT" \
  || die "BucketClaim data is not Ready (reason: $(cond_reason "$NS_A" "$K_CLAIM" data Ready); kubectl -n idp-system logs deploy/idp-broker)"
BUCKET_DATA="$(kubectl -n "$NS_A" get "$K_CLAIM" data -o jsonpath='{.status.bucketName}' 2>/dev/null || true)"
[ -n "$BUCKET_DATA" ] || die "BucketClaim data is Ready but status.bucketName is empty"
info "bucket gs://$BUCKET_DATA"
bucket_json "$BUCKET_DATA" "$tmp/b.json" || die "gcloud cannot describe gs://$BUCKET_DATA: $(first_err)"
want_name="idp-$NS_A-data-$(printf '%s/%s/%s' "$PNUM" "$NS_A" data | sha256 | cut -c1-8)"
ok=1
[ "$BUCKET_DATA" = "$want_name" ] || { ok=""; pfail "3 name $BUCKET_DATA differs from idp-<ns>-<claim>-sha256(number/ns/claim)[:8] = $want_name"; }
printf '%s' "$BUCKET_DATA" | grep -Eq '^idp-rproof-a-data-[0-9a-f]{8}$' || { ok=""; pfail "3 name does not match ^idp-rproof-a-data-[0-9a-f]{8}$"; }
for kv in idp-managed=true idp-namespace="$NS_A" idp-claim=data idp-claim-uid="$UID_DATA"; do
  jq -e --arg k "${kv%%=*}" --arg v "${kv#*=}" '((.labels // {})[$k]) == $v' "$tmp/b.json" >/dev/null 2>&1 \
    || { ok=""; pfail "3 label ${kv%%=*} is not ${kv#*=} (labels: $(jq -c '.labels' "$tmp/b.json" 2>/dev/null))"; }
done
jq -e '((.iamConfiguration.publicAccessPrevention // .public_access_prevention // "") | ascii_downcase) == "enforced"' "$tmp/b.json" >/dev/null 2>&1 \
  || { ok=""; pfail "3 public access prevention is not enforced"; }
jq -e '((.iamConfiguration.uniformBucketLevelAccess.enabled // .uniform_bucket_level_access) == true)' "$tmp/b.json" >/dev/null 2>&1 \
  || { ok=""; pfail "3 uniform bucket-level access is not on"; }
jq -e --arg l "$REGION" '((.location // "") | ascii_downcase) == $l' "$tmp/b.json" >/dev/null 2>&1 \
  || { ok=""; pfail "3 location is not $REGION (got $(jq -r '.location // "?"' "$tmp/b.json"))"; }
jq -e --arg n "$PNUM" '(.projectNumber == null) or ((.projectNumber | tostring) == $n)' "$tmp/b.json" >/dev/null 2>&1 \
  || { ok=""; pfail "3 bucket belongs to another project number"; }
[ -z "$ok" ] || ppass "3 bucket $BUCKET_DATA: name, owner labels, claim UID, public access prevention, uniform access, $REGION"

# --- 4. grant --------------------------------------------------------------------------------------
step "4. ResourceGrant wl-a-data (writer) in $NS_A"
policy_json "$BUCKET_DATA" "$tmp/pol-before.json" || die "cannot read the bucket policy: $(first_err)"
create_cr grant_yaml wl-a-data "$NS_A" wl-a data writer || die "could not create ResourceGrant wl-a-data: $(first_err)"
wait_cond "$NS_A" "$K_GRANT" wl-a-data Ready "$READY_TIMEOUT" \
  || die "ResourceGrant wl-a-data is not Ready (reason: $(cond_reason "$NS_A" "$K_GRANT" wl-a-data Ready))"
M_A="$(member "$NS_A" wl-a)"
t0=$SECONDS
while :; do
  policy_json "$BUCKET_DATA" "$tmp/pol-after.json" && has_binding "$tmp/pol-after.json" roles/storage.objectUser "$M_A" && break
  [ $((SECONDS - t0)) -lt 60 ] || break
  sleep "$POLL"
done
exp="$(jq -nc --arg m "$M_A" '[["roles/storage.objectUser",$m]]')"
added="$(jq -nc --argjson a "$(pairs_of "$tmp/pol-after.json")" --argjson b "$(pairs_of "$tmp/pol-before.json")" '$a - $b')"
removed="$(jq -nc --argjson a "$(pairs_of "$tmp/pol-after.json")" --argjson b "$(pairs_of "$tmp/pol-before.json")" '$b - $a')"
if [ "$added" = "$exp" ] && [ "$removed" = "[]" ]; then
  ppass "4 policy gained exactly roles/storage.objectUser for $M_A (nothing else added or removed)"
else
  pfail "4 policy difference is not exactly the wl-a binding: added=$added removed=$removed"
fi

# --- 5. pod proofs ---------------------------------------------------------------------------------
step "5. pods with the metadata-server token (retry up to ${PROP_TIMEOUT}s per expectation: IAM propagation)"
pod_case 5a "wl-a writes an object (HTTP 200)" 200 "$PROP_TIMEOUT" "rp-a-write" "$NS_A" wl-a write "$BUCKET_DATA" "proof-a.txt"
pod_case 5b "wl-a reads it back, equal to the marker (HTTP 200)" 200 "$PROP_TIMEOUT" "rp-a-read" "$NS_A" wl-a read "$BUCKET_DATA" "proof-a.txt"
pod_case 5c "wl-other (no grant) reads: HTTP 403" 403 "$DENY_TIMEOUT" "rp-other-read" "$NS_A" wl-other read "$BUCKET_DATA" "proof-a.txt"
pod_case 5d "wl-b in $NS_B reads: HTTP 403" 403 "$DENY_TIMEOUT" "rp-b-read" "$NS_B" wl-b read "$BUCKET_DATA" "proof-a.txt"

# --- 6. reader vs writer, revoke -------------------------------------------------------------------
step "6. reader grant for wl-other, then revoke"
M_O="$(member "$NS_A" wl-other)"
if ! create_cr grant_yaml wl-other-data "$NS_A" wl-other data reader; then
  pfail "6 could not create ResourceGrant wl-other-data: $(first_err)"
elif ! wait_cond "$NS_A" "$K_GRANT" wl-other-data Ready "$READY_TIMEOUT"; then
  pfail "6 ResourceGrant wl-other-data is not Ready (reason: $(cond_reason "$NS_A" "$K_GRANT" wl-other-data Ready))"
else
  pod_case 6a "wl-other (reader) reads: HTTP 200" 200 "$PROP_TIMEOUT" "rp-o-read" "$NS_A" wl-other read "$BUCKET_DATA" "proof-a.txt"
  pod_case 6b "wl-other (reader) writes: HTTP 403" 403 "$DENY_TIMEOUT" "rp-o-write" "$NS_A" wl-other write "$BUCKET_DATA" "proof-other.txt"
  kubectl -n "$NS_A" delete "$K_GRANT" wl-other-data --wait=false >/dev/null 2>"$tmp/err" || pfail "6 could not delete wl-other-data: $(first_err)"
  if wait_gone "$NS_A" "$K_GRANT" wl-other-data "$DELETE_TIMEOUT"; then
    pod_case 6c "wl-other read after the grant was deleted: HTTP 403" 403 "$PROP_TIMEOUT" "rp-o-read2" "$NS_A" wl-other read "$BUCKET_DATA" "proof-a.txt"
    policy_json "$BUCKET_DATA" "$tmp/pol6.json" || pfail "6 cannot read the bucket policy: $(first_err)"
    if has_binding "$tmp/pol6.json" roles/storage.objectViewer "$M_O"; then
      pfail "6d policy still contains the principal of wl-other"
    elif ! has_binding "$tmp/pol6.json" roles/storage.objectUser "$M_A"; then
      pfail "6d wl-a's binding disappeared too"
    else
      ppass "6d policy no longer contains wl-other and still contains wl-a"
    fi
  else
    pfail "6 ResourceGrant wl-other-data was not removed within ${DELETE_TIMEOUT}s"
  fi
fi

# --- 7. broker limits ------------------------------------------------------------------------------
if [ "$LIMITS" != on ]; then
  step "7. broker limits"
  pskip "7 broker limits (PROOF_BROKER_LIMITS=off)"
else
  step "7. broker limits as $BROKER_SA (impersonation; conditional bindings may need up to ${COND_TIMEOUT}s)"
  IMP="--impersonate-service-account=$BROKER_SA"
  LT="$(member "$NS_A" limit-test)"
  attempt 0 gcloud auth print-access-token "$IMP"
  if [ "$A_RC" -eq 0 ]; then
    info "impersonation works without an extra grant; none added"
  else
    info "impersonation is not allowed yet: GRANTING roles/iam.serviceAccountTokenCreator to $ME_MEMBER on $BROKER_SA (removed again in the cleanup)"
    TC_MEMBER="$ME_MEMBER" # before the call: a failed or unknown add is still checked and removed in the cleanup
    if gcloud iam service-accounts add-iam-policy-binding "$BROKER_SA" --project="$PROJECT" \
      --member="$ME_MEMBER" --role=roles/iam.serviceAccountTokenCreator >/dev/null 2>"$tmp/err"; then
      attempt "$COND_TIMEOUT" gcloud auth print-access-token "$IMP"
      [ "$A_RC" -eq 0 ] && info "impersonation works after ${A_SECS}s" || info "impersonation still failing after ${A_SECS}s: $(first_err)"
    else
      info "cannot grant tokenCreator: $(first_err)"
      A_RC=1
    fi
  fi
  if [ "$A_RC" -ne 0 ]; then
    pfail "7 cannot impersonate $BROKER_SA: the limit proofs cannot run"
  else
    add_b() { gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_DATA" --project="$PROJECT" --member="$1" --role="$2" "$IMP"; }
    ADD_OK=""
    # (a) positive control: a menu role for a throwaway principal of the proof namespace
    attempt "$COND_TIMEOUT" add_b "$LT" roles/storage.objectViewer
    if [ "$A_RC" -eq 0 ]; then
      ADD_OK=1
      EXTRA_BINDINGS="${EXTRA_BINDINGS}${BUCKET_DATA}|roles/storage.objectViewer|${LT}"$'\n'
      ppass "7a add objectViewer for $NS_A/sa/limit-test as the broker: allowed (${A_SECS}s) [positive control]"
    else
      pfail "7a positive control failed ($(verdict "$A_RC" "$tmp/err"): $(first_err)): the denials below prove nothing and are not evaluated"
    fi
    if [ -n "$ADD_OK" ]; then
      # (b) the custom-role limit
      probe add_b "$LT" roles/storage.admin
      if [ "$PV" = allowed ]; then
        pfail "7b storage.admin was ALLOWED for the broker: the modifiedGrantsByRole limit does not hold"
        EXTRA_BINDINGS="${EXTRA_BINDINGS}${BUCKET_DATA}|roles/storage.admin|${LT}"$'\n'
      else
        v="$PV"
        if [ "$v" = denied ]; then
          pobs "7b add roles/storage.admin as the broker: DENIED ($(first_err))"
          ppass "7b role limit holds: storage.admin refused"
        else
          pfail "7b add storage.admin failed but not as a denial (inconclusive): $(first_err)"
        fi
      fi
      # (c) removal of the menu binding (unproven until now)
      policy_json "$BUCKET_DATA" "$tmp/pol7.json" || true
      if ! has_binding "$tmp/pol7.json" roles/storage.objectViewer "$LT"; then
        pfail "7c inconclusive: the limit-test binding is already gone (removed by the broker's drift cleanup?); re-run"
      elif gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET_DATA" --project="$PROJECT" --member="$LT" \
        --role=roles/storage.objectViewer "$IMP" >"$tmp/out" 2>"$tmp/err"; then
        ppass "7c remove the objectViewer binding as the broker: allowed"
      else
        pfail "7c removing a menu binding as the broker FAILED ($(verdict 1 "$tmp/err")): $(first_err)"
      fi
      # (d) public grant
      probe add_b allUsers roles/storage.objectViewer
      if [ "$PV" = allowed ]; then
        pfail "7d allUsers objectViewer was ALLOWED: the bucket can be made public"
        EXTRA_BINDINGS="${EXTRA_BINDINGS}${BUCKET_DATA}|roles/storage.objectViewer|allUsers"$'\n'
      else
        v="$PV"
        if [ "$v" = denied ]; then
          pobs "7d add allUsers objectViewer as the broker: DENIED ($(first_err))"
          ppass "7d public access prevention / org policy refuses allUsers"
        else
          pfail "7d allUsers failed but not as a denial (inconclusive): $(first_err)"
        fi
      fi
      # (e) outside member: observed only
      if add_b "$ME_MEMBER" roles/storage.objectViewer >"$tmp/out" 2>"$tmp/err"; then
        EXTRA_BINDINGS="${EXTRA_BINDINGS}${BUCKET_DATA}|roles/storage.objectViewer|${ME_MEMBER}"$'\n'
        pobs "7e outside member $ME_MEMBER objectViewer: ALLOWED. Documented accepted risk: the member allow-list is not set ($RUNBOOK)"
        gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET_DATA" --project="$PROJECT" --member="$ME_MEMBER" \
          --role=roles/storage.objectViewer >/dev/null 2>&1 || info "could not remove the 7e binding now; the cleanup retries"
      else
        pobs "7e outside member $ME_MEMBER objectViewer: $(verdict 1 "$tmp/err") ($(first_err)); a member allow-list may be in place"
      fi
      # (f) bucket without the idp- prefix
      NOPFX="rproof-noprefix-$RAND"
      probe gcloud storage buckets create "gs://$NOPFX" --project="$PROJECT" --location="$REGION" --uniform-bucket-level-access \
        --public-access-prevention "$IMP"
      if [ "$PV" = allowed ]; then
        EXTRA_BUCKETS="$EXTRA_BUCKETS $NOPFX"
        pfail "7f creating a bucket without the idp- prefix was ALLOWED (gs://$NOPFX; the cleanup deletes it)"
      else
        v="$PV"
        if [ "$v" = denied ]; then pobs "7f create gs://$NOPFX as the broker: DENIED ($(first_err))"; ppass "7f bucket create without idp- prefix refused"
        else pfail "7f create failed but not as a denial (inconclusive): $(first_err)"; fi
      fi
      # (g) Terraform state bucket, read only
      tfstate="$(gcloud storage buckets list --project="$PROJECT" --filter='name~tfstate' --format='value(name)' 2>/dev/null | head -n 1 | sed 's#^gs://##' || true)"
      if [ -z "$tfstate" ]; then
        pskip "7g no bucket matching tfstate found"
      elif probe gcloud storage buckets get-iam-policy "gs://$tfstate" --project="$PROJECT" --format=json "$IMP"; [ "$PV" = allowed ]; then
        pfail "7g the broker could READ the IAM policy of the Terraform state bucket"
      else
        v="$PV"
        if [ "$v" = denied ]; then pobs "7g get-iam-policy of the state bucket as the broker: DENIED"; ppass "7g state bucket out of reach for the broker"
        else pfail "7g reading the state bucket policy failed but not as a denial (inconclusive): $(first_err)"; fi
      fi
    fi
  fi
fi

# --- 8. release ------------------------------------------------------------------------------------
step "8. release: delete claim data holding an object (expect orphan)"
if [ -z "$(kubectl -n "$NS_A" get "$K_CLAIM" data --ignore-not-found -o name 2>/dev/null || true)" ]; then
  pfail "8 claim data is gone already"
else
  kubectl -n "$NS_A" delete "$K_CLAIM" data --wait=false >/dev/null 2>"$tmp/err" || pfail "8 could not delete claim data: $(first_err)"
  if wait_gone "$NS_A" "$K_CLAIM" data "$DELETE_TIMEOUT"; then
    ppass "8a claim data disappeared (finalizer removed; deletion did not block)"
  else
    pfail "8a claim data still exists after ${DELETE_TIMEOUT}s (kubectl -n $NS_A get $K_CLAIM data -o yaml)"
  fi
  t0=$SECONDS
  while :; do
    bucket_json "$BUCKET_DATA" "$tmp/b8.json" \
      && jq -e '((.labels // {})["idp-orphaned"]) == "true"' "$tmp/b8.json" >/dev/null 2>&1 && break
    [ $((SECONDS - t0)) -lt 60 ] || break
    sleep "$POLL"
  done
  if [ ! -s "$tmp/b8.json" ]; then
    pfail "8b the bucket does not exist any more (expected an orphan): $(first_err)"
  elif jq -e '((.labels // {})["idp-orphaned"]) == "true" and ((((.labels // {})["idp-orphaned-at"]) // "") | test("^[0-9]+$"))' "$tmp/b8.json" >/dev/null 2>&1; then
    objs="$(gcloud storage objects list "gs://$BUCKET_DATA" --project="$PROJECT" --format='value(name)' --limit=5 2>/dev/null || true)"
    if [ -n "$objs" ]; then ppass "8b bucket kept with labels idp-orphaned=true and idp-orphaned-at, object still inside"
    else pfail "8b labelled orphan but the object is gone (cannot list it as you?)"; fi
  else
    pfail "8b bucket exists but lacks idp-orphaned=true / idp-orphaned-at (labels: $(jq -c '.labels' "$tmp/b8.json" 2>/dev/null))"
  fi
  policy_json "$BUCKET_DATA" "$tmp/pol8.json" || true
  if [ -s "$tmp/pol8.json" ] && [ "$(principal_count "$NS_A" "$tmp/pol8.json")" = 0 ]; then
    ppass "8c no principal:// binding of $NS_A left on the orphan"
  else
    pfail "8c principal bindings of $NS_A remain on the orphan (or the policy is unreadable)"
  fi
fi

step "8d/8e claim empty: create, delete with no objects, create again"
if make_claim "$NS_A" empty && wait_cond "$NS_A" "$K_CLAIM" empty Ready "$READY_TIMEOUT"; then
  BUCKET_EMPTY="$(kubectl -n "$NS_A" get "$K_CLAIM" empty -o jsonpath='{.status.bucketName}' 2>/dev/null || true)"
  kubectl -n "$NS_A" delete "$K_CLAIM" empty --wait=false >/dev/null 2>&1 || true
  if [ -n "$BUCKET_EMPTY" ] && wait_gone "$NS_A" "$K_CLAIM" empty "$DELETE_TIMEOUT"; then
    t0=$SECONDS
    gone=""
    while :; do
      if bucket_json "$BUCKET_EMPTY" "$tmp/b8e.json"; then :
      elif grep -qiE '404|not found|does not exist|NotFound' "$tmp/err" && ! grep -qiE '403|permission|denied' "$tmp/err"; then gone=1; break
      fi
      [ $((SECONDS - t0)) -lt 90 ] || break
      sleep "$POLL"
    done
    if [ -n "$gone" ]; then ppass "8d empty claim deleted: gs://$BUCKET_EMPTY is gone (gcloud: not found)"
    else pfail "8d gs://$BUCKET_EMPTY still exists after deleting its empty claim ($(first_err))"; fi
  else
    pfail "8d claim empty did not go away or had no bucketName"
  fi
  if make_claim "$NS_A" empty && wait_cond "$NS_A" "$K_CLAIM" empty Ready "$READY_TIMEOUT"; then
    ppass "8e a re-created claim empty becomes Ready again"
  else
    pfail "8e re-created claim empty is not Ready (reason: $(cond_reason "$NS_A" "$K_CLAIM" empty Ready))"
  fi
else
  pfail "8d claim empty did not become Ready (reason: $(cond_reason "$NS_A" "$K_CLAIM" empty Ready))"
fi

step "9. cleanup runs now (EXIT trap)"
exit 0
