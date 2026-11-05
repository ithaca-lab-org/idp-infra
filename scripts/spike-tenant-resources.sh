#!/usr/bin/env bash
# Spike for ADR 0010 (tenant resources and grants): answers the three "Verify before building"
# points by OBSERVATION. Run by a human from a laptop (gcloud authenticated, kubectl pointed at the
# idp cluster); not part of `make up` or CI. It prints "OBSERVED: ..." lines plus a summary table
# and does not assert PASS/FAIL on the uncertain IAM-condition points. See docs/tenant-resources-spike.md.
#
# Part A (spike point 2): a pod with only a principal:// binding (no ServiceAccount annotation) reads
#   and writes a bucket through the metadata-server token; other ServiceAccounts are denied.
# Part B (spike points 1 and 3): conditional project-level grants for a throwaway service account:
#   resource.name prefix limit on bucket create and bucket IAM, the modifiedGrantsByRole role limit
#   on bucket IAM, and the error text of a bucket-name collision.
#
# Everything created is throwaway, named idp-spike-*<random hex>, labelled idp-spike=true where the
# API supports labels, and removed by the EXIT trap: only objects this run created itself, tracked in
# variables, never by wildcard. Anything that cannot be removed is listed with the command to run.
#
# Environment: SPIKE_PART=A|B|all (default all)   SPIKE_DRY_RUN=1 prints the plan and exits
#              SPIKE_COMMON_BUCKET=<name> bucket name for the collision test (default idp-spike-test)
#              SPIKE_YES=1 skips the confirmation   SPIKE_WAIT=<seconds> propagation retry (default 300)
# Bash 3.2 compatible (macOS). Tokens are never printed or put into argv.
set -euo pipefail
set +x # never trace

REGION="us-central1"
# Pinned: curlimages/curl 8.11.1 (Alpine based, has sh, sed, date, curl). Bump deliberately.
IMAGE="curlimages/curl:8.11.1"
PART="${SPIKE_PART:-all}"
DRY="${SPIKE_DRY_RUN:-0}"
YES="${SPIKE_YES:-0}"
WAIT="${SPIKE_WAIT:-300}"
MARK="idp-spike=true"

START=$SECONDS
tmp=""
RESULTS=""
FAILED_CLEAN=""
# Tracked state: the trap removes exactly these.
NS=""
BUCKETS=""        # space separated bucket names this run created
SA_EMAIL=""       # set once the service account has been created
BIND_COND=""      # condition file of the project binding currently in place
TC_MEMBER=""      # member given tokenCreator on the service account by this run

elapsed() { printf '%ss' "$((SECONDS - START))"; }
step() { printf '\n==> %s  (t+%s)\n' "$*" "$(elapsed)"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'spike: %s\n' "$*" >&2; exit 1; }
row() { RESULTS="${RESULTS}$(printf '%-5s %-52s %s' "$1" "$2" "$3")"$'\n'; }
observed() { printf '    OBSERVED: %s\n' "$*"; }
interp() { printf '      -> %s\n' "$*"; }
oneline() { tr '\n' ' ' <"$1" | cut -c1-"${2:-220}"; }

case "$PART" in A | B | all) ;; *) die "SPIKE_PART must be A, B or all (got '$PART')" ;; esac
want() { [ "$PART" = "all" ] || [ "$PART" = "$1" ]; }

# ---------------------------------------------------------------------------------------------
# Cleanup (EXIT trap). Per step `|| true`; failures are collected and printed with the manual fix.
# ---------------------------------------------------------------------------------------------
clean() { # clean <manual command> <cmd...>
  local manual="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    FAILED_CLEAN="${FAILED_CLEAN}    ${manual}"$'\n'
  fi
  return 0
}

cleanup() {
  local rc=$? b
  trap - EXIT INT TERM
  set +e
  if [ -n "$NS$BUCKETS$SA_EMAIL$BIND_COND$TC_MEMBER" ]; then
    step "cleanup (removes only what this run created)"
    if [ -n "$BIND_COND" ] && [ -n "$SA_EMAIL" ]; then
      clean "remove the conditional roles/storage.admin binding of $SA_EMAIL on project $PROJECT (Console: IAM, or docs/tenant-resources-spike.md)" \
        gcloud projects remove-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA_EMAIL" \
        --role=roles/storage.admin --condition-from-file="$BIND_COND"
    fi
    if [ -n "$TC_MEMBER" ] && [ -n "$SA_EMAIL" ]; then
      clean "gcloud iam service-accounts remove-iam-policy-binding $SA_EMAIL --member=$TC_MEMBER --role=roles/iam.serviceAccountTokenCreator" \
        gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" --member="$TC_MEMBER" \
        --role=roles/iam.serviceAccountTokenCreator --project="$PROJECT"
    fi
    if [ -n "$SA_EMAIL" ]; then
      clean "gcloud iam service-accounts delete $SA_EMAIL --project=$PROJECT" \
        gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT" --quiet
    fi
    for b in $BUCKETS; do
      clean "gcloud storage rm --recursive gs://$b" gcloud storage rm --recursive "gs://$b" --project="$PROJECT"
    done
    if [ -n "$NS" ]; then
      clean "kubectl delete namespace $NS" kubectl delete namespace "$NS" --wait=false --ignore-not-found
    fi
    if [ -n "$FAILED_CLEAN" ]; then
      printf '\nspike: CLEANUP INCOMPLETE. Remove these by hand:\n%s' "$FAILED_CLEAN" >&2
      [ "$rc" -ne 0 ] || rc=1
    else
      info "cleanup complete"
    fi
  fi
  [ -z "$tmp" ] || rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Preflight (read-only)
# ---------------------------------------------------------------------------------------------
step "preflight"
for tool in gcloud curl; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"; done
if want A; then command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH (needed for part A)"; fi

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
{ [ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ]; } || die "no gcloud project set (gcloud config set project ...)"
PNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
[ -n "$PNUM" ] || die "cannot describe project $PROJECT (are you authenticated?)"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
{ [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "(unset)" ]; } || die "no gcloud account (gcloud auth login)"
case "$ACCOUNT" in
  *.gserviceaccount.com) ME_MEMBER="serviceAccount:$ACCOUNT" ;;
  *) ME_MEMBER="user:$ACCOUNT" ;;
esac
CTX=""
if want A; then
  CTX="$(kubectl config current-context 2>/dev/null || true)"
  [ -n "$CTX" ] || die "kubectl has no current context"
  kubectl get --raw /version >/dev/null 2>&1 || die "kubectl context '$CTX' is not reachable"
fi
info "project $PROJECT ($PNUM), account $ACCOUNT, region $REGION"
[ -z "$CTX" ] || info "kubectl context $CTX"

RAND="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
NS_NAME="idp-spike-$RAND"
BUCKET_A="idp-spike-a-$RAND"
BUCKET_B="idp-spike-b-$RAND"
BUCKET_C="idp-spike-c-$RAND"
BUCKET_NOMATCH="spike-nomatch-$RAND"
SA_ID="idp-spike-broker-$RAND"
SA_EMAIL_PLAN="$SA_ID@$PROJECT.iam.gserviceaccount.com"
POOL="$PROJECT.svc.id.goog"
PRINCIPAL_A="principal://iam.googleapis.com/projects/$PNUM/locations/global/workloadIdentityPools/$POOL/subject/ns/$NS_NAME/sa/spike-a"
COMMON_BUCKET="${SPIKE_COMMON_BUCKET:-idp-spike-test}"

if [ "$DRY" = "1" ]; then
  step "dry run: nothing is created. With SPIKE_PART=$PART this run WOULD:"
  if want A; then
    info "A1 create buckets gs://$BUCKET_A (bound) and gs://$BUCKET_B (no binding): uniform access, public access prevention, $REGION"
    info "A2 create namespace $NS_NAME with ServiceAccounts spike-a, spike-b (kubectl, labelled $MARK)"
    info "A3 gcloud storage buckets add-iam-policy-binding gs://$BUCKET_A --role=roles/storage.objectUser"
    info "   --member=$PRINCIPAL_A"
    info "A4 run 4 pods ($IMAGE, restartPolicy Never): spike-a write+read A (200), spike-a list B (403), spike-b read A (403)"
  fi
  if want B; then
    info "B0 try to create gs://$COMMON_BUCKET (collision message only)"
    info "B1 create service account $SA_EMAIL_PLAN; tokenCreator for $ACCOUNT on it only if impersonation fails"
    info "B2 project binding roles/storage.admin + condition resource.name.startsWith(\"projects/_/buckets/idp-spike-\")"
    info "B3 as the SA: b1 create gs://$BUCKET_C, b2 create gs://$BUCKET_NOMATCH, b3 read-only get-iam-policy of the tfstate bucket,"
    info "   b4 objectViewer on $BUCKET_C; then swap the condition for the modifiedGrantsByRole one: b5 objectUser, b6 storage.admin"
  fi
  info "cleanup removes only the objects named above."
  trap - EXIT
  exit 0
fi

cat <<EOF

  WARNING: this creates throwaway resources in PROJECT $PROJECT (and, for part A, in the cluster
  of kubectl context '${CTX:-n/a}'): buckets idp-spike-*, a namespace, a service account and
  conditional IAM bindings. It removes them again on exit. Part B adds a PROJECT-level
  roles/storage.admin binding (conditioned on buckets named idp-spike-*) for a throwaway
  service account for the duration of the run.

EOF
if [ "$YES" != "1" ]; then
  [ -t 0 ] || die "not a terminal; set SPIKE_YES=1 to confirm non-interactively"
  printf '  Type yes to continue: '
  read -r ans
  [ "$ans" = "yes" ] || die "aborted"
fi

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/spike-tenant.XXXXXX")"

# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
label_bucket() { gcloud storage buckets update "gs://$1" --update-labels=idp-spike=true --project="$PROJECT" >/dev/null 2>&1 || info "note: could not label gs://$1"; }

# create_bucket <name> [impersonated-sa]; tracks the name only if the create succeeded.
create_bucket() {
  local name="$1" sa="${2:-}"
  if [ -n "$sa" ]; then
    gcloud storage buckets create "gs://$name" --project="$PROJECT" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention --impersonate-service-account="$sa" \
      >"$tmp/out" 2>"$tmp/err"
  else
    gcloud storage buckets create "gs://$name" --project="$PROJECT" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention >"$tmp/out" 2>"$tmp/err"
  fi
}
track_bucket() { BUCKETS="$BUCKETS $1"; }

# attempt <max-seconds> <cmd...>: runs the command, retrying every 10 s until it succeeds or the
# time is up. Sets A_RC (last exit code) and A_SECS (seconds spent). stdout/stderr go to $tmp.
A_RC=0
A_SECS=0
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
verdict() { # verdict <rc>: allowed | denied | error (by exit code and the stderr text)
  if [ "$1" -eq 0 ]; then
    echo allowed
  elif grep -qiE '403|denied|forbidden|does not have|not authorized|permission|conditional|condition' "$tmp/err"; then
    echo denied
  else
    echo error
  fi
}

# ---------------------------------------------------------------------------------------------
# Part A: pod + Application Default Credentials via the principal binding only
# ---------------------------------------------------------------------------------------------
# Runs in the pod. Env: OP (write|read|list) BUCKET EXPECT (HTTP code) DEADLINE (seconds).
# Retries until the HTTP code equals EXPECT or the deadline passes. Prints one RESULT line; the
# token stays in a shell variable and is never printed.
POD_SH='set -u
start=$(date +%s)
code=000
reason=""
while :; do
  tok=$(curl -s -m 10 -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | sed -n "s/.*\"access_token\" *: *\"\([^\"]*\)\".*/\1/p")
  if [ -z "$tok" ]; then
    code=NOTOKEN
    reason="no-token-from-metadata-server"
  else
    case "$OP" in
      write) code=$(curl -s -m 20 -o /tmp/b -w "%{http_code}" -X POST -H "Authorization: Bearer $tok" -H "Content-Type: text/plain" --data "idp-spike" "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=spike.txt") ;;
      read) code=$(curl -s -m 20 -o /tmp/b -w "%{http_code}" -H "Authorization: Bearer $tok" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o/spike.txt?alt=media") ;;
      list) code=$(curl -s -m 20 -o /tmp/b -w "%{http_code}" -H "Authorization: Bearer $tok" "https://storage.googleapis.com/storage/v1/b/$BUCKET/o") ;;
    esac
    reason=$(sed -n "s/.*\"reason\" *: *\"\([^\"]*\)\".*/\1/p" /tmp/b | head -n 1)
  fi
  tok=""
  el=$(( $(date +%s) - start ))
  [ "$code" = "$EXPECT" ] && break
  [ "$el" -ge "$DEADLINE" ] && break
  sleep 10
done
echo "RESULT code=$code elapsed=$el reason=${reason:-none}"'

POD_CODE=""
POD_SECS=""
POD_REASON=""
# run_pod <name> <serviceaccount> <op> <bucket> <expect> <deadline>
run_pod() {
  local name="$1" sa="$2" op="$3" bucket="$4" expect="$5" deadline="$6" phase="" t0=$SECONDS line=""
  POD_CODE="n/a"
  POD_SECS="n/a"
  POD_REASON="pod did not run"
  if ! kubectl -n "$NS" run "$name" --image="$IMAGE" --restart=Never --labels="idp-spike=true" \
    --overrides="{\"spec\":{\"serviceAccountName\":\"$sa\"}}" \
    --env="OP=$op" --env="BUCKET=$bucket" --env="EXPECT=$expect" --env="DEADLINE=$deadline" \
    --command -- sh -c "$POD_SH" >/dev/null 2>"$tmp/err"; then
    POD_REASON="kubectl run failed: $(oneline "$tmp/err" 120)"
    return 0
  fi
  while [ $((SECONDS - t0)) -lt $((deadline + 240)) ]; do
    phase="$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 5
  done
  line="$(kubectl -n "$NS" logs "$name" 2>/dev/null | grep '^RESULT ' | tail -n 1 || true)"
  if [ -z "$line" ]; then
    POD_REASON="no RESULT line (pod phase: ${phase:-unknown})"
    return 0
  fi
  POD_CODE="$(printf '%s' "$line" | sed -n 's/.*code=\([^ ]*\).*/\1/p')"
  POD_SECS="$(printf '%s' "$line" | sed -n 's/.*elapsed=\([^ ]*\).*/\1/p')"
  POD_REASON="$(printf '%s' "$line" | sed -n 's/.*reason=\(.*\)$/\1/p')"
}

pod_case() { # pod_case <id> <desc> <expect> <deadline> <pod> <sa> <op> <bucket>
  local id="$1" desc="$2" expect="$3" deadline="$4"
  run_pod "$5" "$6" "$7" "$8" "$expect" "$deadline"
  observed "$id $desc: HTTP $POD_CODE after ${POD_SECS}s (expected $expect), reason=$POD_REASON"
  if [ "$POD_CODE" = "$expect" ]; then
    row "$id" "$desc" "HTTP $POD_CODE as expected (${POD_SECS}s)"
  else
    row "$id" "$desc" "HTTP $POD_CODE, EXPECTED $expect (${POD_SECS}s) reason=$POD_REASON"
    interp "differs from the expectation: see docs/tenant-resources-spike.md for what that means"
  fi
}

part_a() {
  step "A1 buckets gs://$BUCKET_A and gs://$BUCKET_B"
  create_bucket "$BUCKET_A" || die "cannot create $BUCKET_A: $(oneline "$tmp/err")"
  track_bucket "$BUCKET_A"
  label_bucket "$BUCKET_A"
  create_bucket "$BUCKET_B" || die "cannot create $BUCKET_B: $(oneline "$tmp/err")"
  track_bucket "$BUCKET_B"
  label_bucket "$BUCKET_B"

  step "A2 namespace $NS_NAME with ServiceAccounts spike-a, spike-b (no annotations)"
  NS="$NS_NAME"
  kubectl create namespace "$NS" >/dev/null || die "cannot create namespace $NS"
  kubectl label namespace "$NS" idp-spike=true >/dev/null || info "note: could not label namespace"
  kubectl -n "$NS" create serviceaccount spike-a >/dev/null || die "cannot create ServiceAccount spike-a"
  kubectl -n "$NS" create serviceaccount spike-b >/dev/null || die "cannot create ServiceAccount spike-b"

  step "A3 bind only the spike-a principal as roles/storage.objectUser on gs://$BUCKET_A"
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_A" --project="$PROJECT" \
    --member="$PRINCIPAL_A" --role=roles/storage.objectUser >/dev/null 2>"$tmp/err" \
    || die "cannot add the principal binding: $(oneline "$tmp/err")"
  info "bound $PRINCIPAL_A"

  step "A4 pods (retry up to ${WAIT}s per expectation for IAM propagation)"
  pod_case A1 "spike-a writes object to bucket A" 200 "$WAIT" p-write-a spike-a write "$BUCKET_A"
  pod_case A2 "spike-a reads object from bucket A" 200 "$WAIT" p-read-a spike-a read "$BUCKET_A"
  pod_case A3 "spike-a lists bucket B (no binding)" 403 60 p-list-b spike-a list "$BUCKET_B"
  pod_case A4 "spike-b reads bucket A (other ServiceAccount)" 403 60 p-read-a-b spike-b read "$BUCKET_A"
  interp "200/200 for spike-a and 403 for the rest: a principal:// binding alone gives pods ADC access, scoped per ServiceAccount."
  interp "NOTE: curl on the metadata token only proves the credential path; the Go and gcloud clients are not exercised here."
}

# ---------------------------------------------------------------------------------------------
# Part B: IAM conditions
# ---------------------------------------------------------------------------------------------
write_cond() { # write_cond <file> <title> <expression-json-escaped>
  printf '{"title": "%s", "description": "idp-spike throwaway", "expression": "%s"}\n' "$2" "$3" >"$1"
}

part_b() {
  local cond1="$tmp/cond1.json" cond2="$tmp/cond2.json" tfstate="" v b4v=""
  # JSON-escaped CEL expressions
  write_cond "$cond1" "idp-spike-prefix" 'resource.name.startsWith(\"projects/_/buckets/idp-spike-\")'
  write_cond "$cond2" "idp-spike-prefix-rolelimit" 'resource.name.startsWith(\"projects/_/buckets/idp-spike-\") && api.getAttribute('"'"'iam.googleapis.com/modifiedGrantsByRole'"'"', []).hasOnly(['"'"'roles/storage.objectViewer'"'"','"'"'roles/storage.objectUser'"'"'])'

  step "B0 bucket name collision (spike point 3): create gs://$COMMON_BUCKET"
  if create_bucket "$COMMON_BUCKET"; then
    track_bucket "$COMMON_BUCKET"
    observed "gs://$COMMON_BUCKET was free and is now created in this project (removed in cleanup); no collision text observed"
    interp "try again with a name you know exists elsewhere with SPIKE_COMMON_BUCKET=<name> to see the message."
    row B0 "bucket name collision" "name was free; no error text"
  else
    observed "create gs://$COMMON_BUCKET failed: $(oneline "$tmp/err" 300)"
    interp "this is the text the broker must map to a clear 'name taken' condition (or retry with a suffix)."
    row B0 "bucket name collision" "$(oneline "$tmp/err" 70)"
  fi

  step "B1 throwaway service account $SA_ID"
  gcloud iam service-accounts create "$SA_ID" --project="$PROJECT" \
    --display-name="idp-spike throwaway (idp-spike=true)" >/dev/null 2>"$tmp/err" \
    || die "cannot create the service account: $(oneline "$tmp/err")"
  SA_EMAIL="$SA_EMAIL_PLAN"
  info "created $SA_EMAIL"

  step "B2 impersonation: is tokenCreator needed for $ACCOUNT?"
  attempt 0 gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL"
  if [ "$A_RC" -eq 0 ]; then
    info "impersonation works without an extra grant; none added"
  else
    info "impersonation not allowed yet: GRANTING roles/iam.serviceAccountTokenCreator to $ME_MEMBER on $SA_EMAIL (removed in cleanup)"
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$PROJECT" \
      --member="$ME_MEMBER" --role=roles/iam.serviceAccountTokenCreator >/dev/null 2>"$tmp/err" \
      || die "cannot grant tokenCreator: $(oneline "$tmp/err")"
    TC_MEMBER="$ME_MEMBER"
    attempt 180 gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL"
    [ "$A_RC" -eq 0 ] || die "impersonation still failing after ${A_SECS}s: $(oneline "$tmp/err")"
    info "impersonation works after ${A_SECS}s"
  fi

  step "B3 project binding roles/storage.admin with condition idp-spike-prefix"
  if gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA_EMAIL" \
    --role=roles/storage.admin --condition-from-file="$cond1" >/dev/null 2>"$tmp/err"; then
    BIND_COND="$cond1"
    observed "gcloud accepted the condition resource.name.startsWith(\"projects/_/buckets/idp-spike-\")"
    row B-syn "condition 1 (prefix) accepted by gcloud/API" "accepted"
  else
    observed "gcloud/API REJECTED condition 1: $(oneline "$tmp/err" 300)"
    interp "prefix conditions on resource.name cannot be set this way; the rest of part B is skipped."
    row B-syn "condition 1 (prefix) accepted by gcloud/API" "REJECTED"
    return 0
  fi

  step "B4 observations as the service account (b1 retried up to ${WAIT}s: conditional bindings propagate slowly)"
  local imp="--impersonate-service-account=$SA_EMAIL"
  # b1
  attempt "$WAIT" create_bucket "$BUCKET_C" "$SA_EMAIL"
  v="$(verdict "$A_RC")"
  if [ "$A_RC" -eq 0 ]; then track_bucket "$BUCKET_C"; label_bucket "$BUCKET_C"; fi
  observed "b1 create gs://$BUCKET_C (matches prefix) as SA: $v after ${A_SECS}s ${A_RC:+rc=$A_RC} $([ "$A_RC" -eq 0 ] || oneline "$tmp/err" 160)"
  interp "allowed = the prefix condition is honoured on bucket CREATE (resource.name is set at create); denied = it is not usable for create."
  row b1 "create bucket matching idp-spike-* (as SA)" "$v (${A_SECS}s)"
  if [ "$A_RC" -ne 0 ]; then
    info "creating gs://$BUCKET_C as the invoking user so b4..b6 can still run"
    if create_bucket "$BUCKET_C"; then track_bucket "$BUCKET_C"; label_bucket "$BUCKET_C"; fi
  fi
  # b2
  if create_bucket "$BUCKET_NOMATCH" "$SA_EMAIL"; then
    track_bucket "$BUCKET_NOMATCH"
    v=allowed
  else
    v="$(verdict 1)"
  fi
  observed "b2 create gs://$BUCKET_NOMATCH (does NOT match prefix) as SA: $v $([ "$v" = allowed ] || oneline "$tmp/err" 160)"
  interp "denied = prefix limit holds for create (needed). allowed = the condition does not restrict create; broker would be able to create any bucket."
  row b2 "create bucket NOT matching prefix (as SA)" "$v"
  # b3
  tfstate="$(gcloud storage buckets list --project="$PROJECT" --filter='name~tfstate' --format='value(name)' 2>/dev/null | head -n 1 | sed 's#^gs://##' || true)"
  if [ -z "$tfstate" ]; then
    observed "b3 skipped: no bucket matching 'tfstate' found"
    row b3 "get-iam-policy of the tfstate bucket (read only)" "skipped (not found)"
  else
    if gcloud storage buckets get-iam-policy "gs://$tfstate" --project="$PROJECT" "$imp" >"$tmp/out" 2>"$tmp/err"; then
      v=allowed
    else
      v="$(verdict 1)"
    fi
    observed "b3 get-iam-policy of the state bucket as SA (read only): $v $([ "$v" = allowed ] || oneline "$tmp/err" 160)"
    interp "denied = a non-matching bucket cannot even be read, so the state bucket is out of reach. allowed = conditions do not guard bucket reads (setIamPolicy may still be guarded, see b4)."
    row b3 "get-iam-policy of tfstate bucket (as SA)" "$v"
  fi
  # b4
  attempt 0 gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_C" --project="$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" --role=roles/storage.objectViewer "$imp"
  b4v="$(verdict "$A_RC")"
  observed "b4 set objectViewer binding on gs://$BUCKET_C as SA: $b4v $([ "$A_RC" -eq 0 ] || oneline "$tmp/err" 160)"
  interp "allowed = the prefix condition permits bucket IAM writes on matching buckets (broker design works for grants)."
  row b4 "setIamPolicy objectViewer on idp-spike-c (as SA)" "$b4v"

  step "B5 second experiment: add the modifiedGrantsByRole limit to the condition"
  if gcloud projects remove-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA_EMAIL" \
    --role=roles/storage.admin --condition-from-file="$cond1" >/dev/null 2>"$tmp/err"; then
    BIND_COND=""
  else
    observed "could not remove condition 1 ($(oneline "$tmp/err" 160)); skipping the role-limit experiment"
    row B-syn2 "condition 2 (role limit) accepted by gcloud/API" "skipped"
    return 0
  fi
  if gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA_EMAIL" \
    --role=roles/storage.admin --condition-from-file="$cond2" >/dev/null 2>"$tmp/err"; then
    BIND_COND="$cond2"
    observed "gcloud accepted the modifiedGrantsByRole condition on a storage.admin binding"
    row B-syn2 "condition 2 (role limit) accepted by gcloud/API" "accepted"
  else
    observed "gcloud/API REJECTED condition 2: $(oneline "$tmp/err" 300)"
    interp "the role limit cannot be expressed on this binding: menu is enforced only in broker code plus admission (ADR 0010 spike point 1). Skipping b5/b6."
    row B-syn2 "condition 2 (role limit) accepted by gcloud/API" "REJECTED"
    return 0
  fi
  info "waiting 60s for the new condition to propagate (the old binding may linger briefly)"
  sleep 60
  attempt "$WAIT" gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_C" --project="$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" --role=roles/storage.objectUser "$imp"
  v="$(verdict "$A_RC")"
  observed "b5 grant objectUser on gs://$BUCKET_C as SA (in the allowed list): $v after ${A_SECS}s $([ "$A_RC" -eq 0 ] || oneline "$tmp/err" 160)"
  interp "allowed = the role-limited condition still permits the menu roles. denied = the attribute blocks even allowed roles (attribute unsupported for bucket IAM?)."
  row b5 "grant objectUser on idp-spike-c (as SA, role-limited)" "$v (${A_SECS}s)"
  attempt 0 gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_C" --project="$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" --role=roles/storage.admin "$imp"
  v="$(verdict "$A_RC")"
  observed "b6 grant roles/storage.admin on gs://$BUCKET_C as SA (NOT in the allowed list): $v $([ "$A_RC" -eq 0 ] || oneline "$tmp/err" 160)"
  if [ "$v" = "allowed" ]; then
    observed "role limit NOT enforced on bucket IAM"
    interp "the menu must be enforced in broker code plus the admission policy only; the Opus review must say so."
  else
    interp "denied = role limit is enforceable for bucket IAM (provided b5 was allowed); the menu can be a second line of defence in IAM."
  fi
  row b6 "grant storage.admin on idp-spike-c (as SA, role-limited)" "$v"
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
if want A; then part_a; fi
if want B; then part_b; fi

step "summary (OBSERVATIONS, not pass/fail; paste this table back)"
printf '%-5s %-52s %s\n' ID WHAT RESULT
printf '%s' "$RESULTS"
echo
info "done in $(elapsed); cleanup runs now"
exit 0
