#!/usr/bin/env bash
# Proves on a running cluster that per-namespace Vault access works end to end and is isolated
# (idp-gitops workloads/vault/README.md, "Per-namespace access"; docs/vault.md, "Proving
# per-namespace isolation"). Run by a human from a laptop with kubectl pointed at the cluster as a
# cluster admin; it is not part of `make up` or CI.
#
# What it does (and undoes):
#   1. preflight: tools, Vault initialized and unsealed, operator VAULT_ENABLED=true, VSO objects,
#      ServiceAccount vault/vault-proof; refuses when TeamNamespaces/namespaces vproof-a or
#      vproof-b already exist.
#   2. a short-lived admin token: a 10-minute ServiceAccount token for vault/vault-proof (audience
#      vault) logs in to Vault's Kubernetes auth role vault-proof (idp-gitops workloads/vault,
#      "Proof role vault-proof": only kv/vproof-a/ and kv/vproof-b/ plus a read of role
#      portal-secrets; 1 h, not renewable). No root token, no generate-root (Vault 2.0 requires a
#      token for it), no recovery keys.
#   3. creates the throwaway TeamNamespaces vproof-a and vproof-b (label
#      idp.ithaca-idp.com/vault-proof=true) and waits for Ready, VaultReady and vault-reader.
#   4. writes kv/vproof-a/hello and kv/vproof-b/hello (random values, never shown).
#   5. P1/P2: a VaultStaticSecret in each namespace syncs its own value (compared by sha256).
#   6. P3/P4: a VaultStaticSecret pointing at the other namespace's path never syncs and VSO
#      reports that Vault denied it (403 / permission denied).
#   7. P7: the portal's Vault role portal-secrets is write-only (skipped if the role does not exist).
#   8. P5/P6: deleting a TeamNamespace purges its kv/<ns>/ and leaves the other one intact.
#   A PASS/FAIL line per proof and a summary. Cleanup (TeamNamespaces, KV leftovers, the admin and
#   portal Vault tokens via revoke-self, temp files) runs on every exit, also on failure or Ctrl-C.
#
# Usage: ./scripts/vault-proof.sh            run the proof
#        ./scripts/vault-proof.sh --cleanup  remove leftovers of an interrupted run
#
# Secrets (ServiceAccount JWTs, admin and portal Vault tokens, the test values) only live in 0600
# files in a private temp dir and in pipes: never in argv (so not in `ps`), env, stdout, stderr or
# logs. They reach vault-0 on `kubectl exec -i` STDIN only. Values are compared by sha256, never
# printed. Bash 3.2 compatible (macOS).
set -euo pipefail
set +x # never trace: tokens pass through this script

VAULT_NS="vault"
VAULT_POD="vault-0"
NS_A="vproof-a"
NS_B="vproof-b"
MARK_KEY="idp.ithaca-idp.com/vault-proof"
MARK_JSONPATH='{.metadata.labels.idp\.ithaca-idp\.com/vault-proof}'
PROOF_ROLE="vault-proof" # Vault Kubernetes auth role and policy (idp-gitops workloads/vault/config-job.yaml)
PROOF_SA="vault-proof"   # ServiceAccount vault/vault-proof (idp-gitops workloads/vault/proof-serviceaccount.yaml)
PROOF_TOKEN_MAX=3600     # the role's token_max_ttl: the admin token dies after 1 h, whatever happens
PORTAL_ROLE="portal-secrets"
PORTAL_SA_NS="idp-system"
PORTAL_SA="portal-api"
READY_TIMEOUT="${PROOF_READY_TIMEOUT:-180}"   # per TeamNamespace: Ready + VaultReady + vault-reader
SYNC_TIMEOUT="${PROOF_SYNC_TIMEOUT:-120}"     # positive proof: VSO syncs the own path
DENY_WAIT="${PROOF_DENY_WAIT:-60}"            # negative proof: how long the foreign path must stay unsynced
DELETE_TIMEOUT="${PROOF_DELETE_TIMEOUT:-300}" # per TeamNamespace deletion incl. the operator's Vault purge
P7_METADATA="${PROOF_P7_METADATA:-denied}"    # denied: expect read/list on kv/metadata/<ns>/ denied for the portal; skip
POLL="${PROOF_POLL:-5}"
ME="./scripts/vault-proof.sh"
REBUILD="the vault-config Job only configures a freshly initialized Vault, so a Vault from before role $PROOF_ROLE was added needs a rebuild (make down, make up)"

# Runs inside vault-0. Args: <op> <path>. STDIN: a token on the first line, then (write only) the
# JSON request body. Exit 10 = login failed (stderr says why); otherwise the vault CLI's exit code
# (2 with "No value found" on stderr = nothing at that path; "permission denied" / 403 = denied).
VAULT_OP_IN_POD='set -eu
umask 077
cleanup() { rm -f "$HOME/.vault-token"; }
trap cleanup EXIT
trap "exit 1" INT TERM HUP
IFS= read -r t || exit 10
printf "%s" "$t" | vault login -no-print - >/dev/null || exit 10
t=""
case "$1" in
  write) vault write "$2" - >/dev/null ;;
  read) vault read -format=json "$2" ;;
  list) vault list -format=json "$2" ;;
  delete) vault delete "$2" >/dev/null ;;
  revoke-self) vault token revoke -self >/dev/null ;;
  *) exit 64 ;;
esac'

# Runs inside vault-0. Arg: the Kubernetes auth role. STDIN: a ServiceAccount JWT (jwt=- reads it).
# STDOUT: the login JSON (holds the Vault token; the caller keeps it in a 0600 file).
VAULT_K8S_LOGIN_IN_POD='set -eu
vault write -format=json auth/kubernetes/login role="$1" jwt=-'

START=$SECONDS
RESULTS=""
FAILED=0
MODE="proof"
tmp=""
CREATED_A=""
CREATED_B=""
HASH_A=""
HASH_B=""
KV_LEFT=""     # kv keys (mount-relative) this run wrote and has not seen removed
MANUAL_LEFT="" # kv keys only a human can remove now

elapsed() { printf '%ss' "$((SECONDS - START))"; }
step() { printf '\n==> %s  (t+%s)\n' "$*" "$(elapsed)"; }
info() { printf '    %s\n' "$*"; }
record() { RESULTS="${RESULTS}$(printf '%-5s %s' "$1" "$2")"$'\n'; }
ppass() { record PASS "$*"; printf '    PASS  %s\n' "$*"; }
pskip() { record SKIP "$*"; printf '    SKIP  %s\n' "$*"; }
pfail() { record FAIL "$*"; FAILED=1; printf '    FAIL  %s\n' "$*" >&2; }
die() { record FAIL "setup: $*"; FAILED=1; printf '    FAIL  setup: %s\n' "$*" >&2; exit 1; }
first_err() { head -n 1 "$tmp/err" 2>/dev/null | cut -c1-200; }
denied_err() { grep -qiE '403|permission denied' "$tmp/err" 2>/dev/null; }

kv_left_add() { KV_LEFT="$KV_LEFT $1"; }
kv_left_del() {
  local k out=""
  for k in $KV_LEFT; do [ "$k" = "$1" ] || out="$out $k"; done
  KV_LEFT="$out"
}
kv_left_drop_ns() {
  local k out=""
  for k in $KV_LEFT; do case "$k" in "$1"/*) ;; *) out="$out $k" ;; esac; done
  KV_LEFT="$out"
}

usage() {
  printf 'Usage: %s [--cleanup]\n' "$ME"
  printf '  (no flag)  prove per-namespace Vault access and isolation with the throwaway\n'
  printf '             TeamNamespaces %s and %s (created and removed again)\n' "$NS_A" "$NS_B"
  printf '  --cleanup  remove leftovers of an interrupted run (only objects labelled %s=true)\n' "$MARK_KEY"
  printf 'See docs/vault.md, "Proving per-namespace isolation".\n'
}

case "${1:-}" in
  "") ;;
  --cleanup) MODE="cleanup" ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

# --- helpers ------------------------------------------------------------------------------------
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

vexec() { kubectl -n "$VAULT_NS" exec "$VAULT_POD" -- "$@"; }
vexec_in() { kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- "$@"; }

# vault_op <token-file> <op> <path> [<body-file>]: the token and the body go on STDIN only.
vault_op() {
  local tok="$1" op="$2" path="$3" body="${4:-}"
  {
    cat "$tok"
    printf '\n'
    if [ -n "$body" ]; then cat "$body"; fi
  } | vexec_in sh -c "$VAULT_OP_IN_POD" sh "$op" "$path"
}

# kv_state <ns>: prints gone, present or error (LIST kv/metadata/<ns>/ with the admin token).
kv_state() {
  local rc n
  vault_op "$tmp/admin-token" list "kv/metadata/$1/" >"$tmp/list.json" 2>"$tmp/err" && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    n="$(jq 'if type == "array" then length else (.keys // [] | length) end' "$tmp/list.json" 2>/dev/null || echo x)"
    case "$n" in 0) echo gone ;; x) echo error ;; *) echo present ;; esac
  elif [ "$rc" = 2 ] && grep -q 'No value found' "$tmp/err"; then
    echo gone
  else
    echo error
  fi
  rm -f "$tmp/list.json"
}

# kv_hash <ns>: sha256 of kv/<ns>/hello's message (empty if unreadable). The value only passes a pipe.
kv_hash() {
  if vault_op "$tmp/admin-token" read "kv/data/$1/hello" >"$tmp/read.json" 2>"$tmp/err"; then
    jq -j '.data.data.message // ""' "$tmp/read.json" | sha256
  fi
  rm -f "$tmp/read.json"
}

# k8s_hash <ns> <secret>: sha256 of the Secret's key message; empty when the Secret or key is absent.
k8s_hash() {
  kubectl -n "$1" get secret "$2" --ignore-not-found -o jsonpath='{.data.message}' >"$tmp/k8s-msg" 2>/dev/null || true
  if [ -s "$tmp/k8s-msg" ]; then
    base64 --decode <"$tmp/k8s-msg" | sha256
  fi
  rm -f "$tmp/k8s-msg"
}

secret_exists() { [ -n "$(kubectl -n "$1" get secret "$2" --ignore-not-found -o name 2>/dev/null || true)" ]; }

remaining() {
  local r=$(($1 - SECONDS))
  [ "$r" -ge 1 ] || r=1
  echo "$r"
}

# tns_state <name>: ours | foreign | terminating | absent | error
tns_state() {
  local t ns
  t="$(kubectl get teamnamespace "$1" --ignore-not-found -o jsonpath="{.metadata.name}|$MARK_JSONPATH" 2>"$tmp/err")" || { echo error; return 0; }
  ns="$(kubectl get namespace "$1" --ignore-not-found -o jsonpath='{.metadata.name}|{.status.phase}' 2>"$tmp/err")" || { echo error; return 0; }
  if [ "$t" = "$1|true" ]; then
    echo ours
  elif [ -n "$t" ]; then
    echo foreign
  elif [ "$ns" = "$1|Terminating" ]; then
    echo terminating
  elif [ -n "$ns" ]; then
    echo foreign
  else
    echo absent
  fi
}

# delete_if_ours <name>: deletes the TeamNamespace only if it carries this script's label, then
# waits (one DELETE_TIMEOUT in total) for it (the operator's finalizer purges kv/<name>/ first)
# and its namespace to be gone.
delete_if_ours() {
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


tns_yaml() {
  printf 'apiVersion: idp.ithaca-idp.com/v1alpha1\nkind: TeamNamespace\nmetadata:\n  name: %s\n  labels:\n    %s: "true"\nspec:\n  businessUnit: verify-bu\n  owner: verify@example.com\n  size: small\n  orderId: %s\n' \
    "$1" "$MARK_KEY" "$2"
}

# vss_yaml <namespace> <name> <kv path> <destination Secret>
vss_yaml() {
  printf 'apiVersion: secrets.hashicorp.com/v1beta1\nkind: VaultStaticSecret\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  vaultAuthRef: vault-reader\n  mount: kv\n  type: kv-v2\n  path: %s\n  refreshAfter: 10s\n  destination:\n    name: %s\n    create: true\n' \
    "$2" "$1" "$3" "$4"
}

# warning_reason <namespace> <VaultStaticSecret>: first Warning event reason ("" if none)
warning_reason() {
  kubectl -n "$1" get events \
    --field-selector "involvedObject.kind=VaultStaticSecret,involvedObject.name=$2,type=Warning" \
    -o jsonpath='{range .items[*]}{.reason}{"\n"}{end}' 2>/dev/null | head -n 1 || true
}

# denied_403 <namespace> <VaultStaticSecret>: does a Warning message show that Vault denied the
# read (403 / permission denied)? The messages are never printed.
denied_403() {
  kubectl -n "$1" get events \
    --field-selector "involvedObject.kind=VaultStaticSecret,involvedObject.name=$2,type=Warning" \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -qiE '403|permission denied'
}

# --- cleanup, always ----------------------------------------------------------------------------
summary() {
  printf '\n===== vault-proof.sh summary (took %s) =====\n' "$(elapsed)"
  printf '%s' "$RESULTS"
  if [ "$FAILED" = 0 ]; then
    printf 'RESULT: all proofs passed\n'
  else
    printf 'RESULT: FAILED (see the FAIL lines above; docs/vault.md, "Proving per-namespace isolation")\n' >&2
  fi
}

cleanup() {
  local rc=$? n k admin_ok=1
  set +e
  trap - EXIT
  trap 'printf "cleanup interrupted: run %s --cleanup\n" "$ME" >&2; exit 130' INT TERM HUP
  [ "$rc" = 0 ] || FAILED=1
  if [ "$MODE" = proof ]; then
    step "cleanup"
    if [ -s "$tmp/portal-token" ]; then
      vault_op "$tmp/portal-token" revoke-self - >/dev/null 2>&1 && info "revoked the portal-secrets test token"
      rm -f "$tmp/portal-token"
    fi
    for n in "$NS_A" "$NS_B"; do
      if { [ "$n" = "$NS_A" ] && [ -n "$CREATED_A" ]; } || { [ "$n" = "$NS_B" ] && [ -n "$CREATED_B" ]; }; then
        info "deleting TeamNamespace $n (waiting up to ${DELETE_TIMEOUT}s, the operator purges kv/$n/ first)"
        if delete_if_ours "$n"; then
          info "TeamNamespace and namespace $n removed"
        else
          pfail "cleanup: $n not fully removed (kubectl get teamnamespace $n -o yaml; then $ME --cleanup)"
        fi
      fi
    done
    if [ -s "$tmp/admin-token" ]; then
      # Usually already purged by the operator; deleting a missing key is a no-op. If the token
      # does not work any more (expired), the keys are listed for the human below.
      for k in $KV_LEFT; do
        if vault_op "$tmp/admin-token" delete "kv/metadata/$k" >/dev/null 2>"$tmp/err"; then
          kv_left_del "$k"
        else
          admin_ok=""
          MANUAL_LEFT="$MANUAL_LEFT $k"
        fi
      done
      if vault_op "$tmp/admin-token" revoke-self - >/dev/null 2>&1; then
        info "revoked the $PROOF_ROLE token"
      elif [ -n "$admin_ok" ]; then
        info "could not revoke the $PROOF_ROLE token; it dies at its TTL (at most 1 h) anyway"
      else
        info "could not revoke the $PROOF_ROLE token (expired already?); it dies at its TTL anyway"
      fi
    else
      for k in $KV_LEFT; do MANUAL_LEFT="$MANUAL_LEFT $k"; done
    fi
    if [ -n "${MANUAL_LEFT// /}" ]; then
      pfail "cleanup: KV keys written by this run could not be removed (admin token expired or refused)"
      info "keys under kv/$NS_A/ and kv/$NS_B/: the operator purges them whenever a TeamNamespace of that"
      info "name is created or deleted, so the next run of $ME removes them before it writes anything."
      info "keys anywhere else can only be removed by rebuilding Vault (no admin token exists, docs/vault.md):"
      for k in $MANUAL_LEFT; do info "  kv/$k"; done
    fi
  fi
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    rm -f "$tmp"/* 2>/dev/null
    rmdir "$tmp" 2>/dev/null
  fi
  summary
  [ "$FAILED" = 0 ] && exit 0
  exit 1
}

# --- tools and temp dir -------------------------------------------------------------------------
tools="kubectl jq"
[ "$MODE" = proof ] && tools="kubectl jq base64 od awk"
for t in $tools; do
  command -v "$t" >/dev/null 2>&1 || { printf 'vault-proof: %s not found on PATH\n' "$t" >&2; exit 1; }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  printf 'vault-proof: neither sha256sum nor shasum found on PATH\n' >&2
  exit 1
fi

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vault-proof.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- --cleanup ----------------------------------------------------------------------------------
if [ "$MODE" = cleanup ]; then
  step "cleanup of leftovers (only TeamNamespaces labelled $MARK_KEY=true)"
  for n in "$NS_A" "$NS_B"; do
    st="$(tns_state "$n")"
    case "$st" in
      absent) ppass "$n: nothing left" ;;
      ours | terminating)
        info "removing $n (waiting up to ${DELETE_TIMEOUT}s)"
        if delete_if_ours "$n"; then ppass "$n: removed"; else pfail "$n: still present (kubectl get teamnamespace $n -o yaml; VaultPurgePending?)"; fi
        ;;
      foreign) pfail "$n exists but was not created by this script (no label $MARK_KEY=true): not touched" ;;
      *) pfail "$n: could not read its state ($(first_err))" ;;
    esac
  done
  info "KV data under kv/$NS_A/ and kv/$NS_B/ is purged by the operator when a TeamNamespace of that"
  info "name is created or deleted. A leftover $PROOF_ROLE Vault token expires by itself (at most 1 h)."
  exit 0
fi

# --- 1. preflight -------------------------------------------------------------------------------
step "1. preflight"
ctx="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$ctx" ] || die "kubectl has no current context (gcloud container clusters get-credentials idp --dns-endpoint ...)"
info "kubectl context: $ctx"

if vstatus="$(vexec vault status -format=json 2>"$tmp/err")"; then vrc=0; else vrc=$?; fi
vinit="$(printf '%s' "$vstatus" | jq -r '.initialized' 2>/dev/null || true)"
vsealed="$(printf '%s' "$vstatus" | jq -r '.sealed' 2>/dev/null || true)"
[ "$vinit" = true ] || die "Vault is not initialized or not reachable (vault status exit $vrc: $(first_err)); run ./scripts/bootstrap-secrets.sh"
[ "$vrc" = 0 ] && [ "$vsealed" = false ] || die "Vault is sealed (vault status exit $vrc); see docs/vault.md, Troubleshooting"
info "Vault is initialized and unsealed"

venabled="$(kubectl -n idp-system get deployment idp-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VAULT_ENABLED")].value}' 2>/dev/null || true)"
[ "$venabled" = true ] || die "the idp-operator does not run with VAULT_ENABLED=true (got '${venabled:-unset}'): per-namespace Vault access is off"
kubectl get crd teamnamespaces.idp.ithaca-idp.com vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1 \
  || die "CRD teamnamespaces.idp.ithaca-idp.com or vaultstaticsecrets.secrets.hashicorp.com is missing"
kubectl -n vault-secrets-operator get vaultconnection idp-vault >/dev/null 2>&1 \
  || die "VaultConnection vault-secrets-operator/idp-vault is missing (idp-gitops workloads/vault-secrets-operator)"
info "operator has VAULT_ENABLED=true; CRDs and VaultConnection vault-secrets-operator/idp-vault are present"
kubectl -n "$VAULT_NS" get serviceaccount "$PROOF_SA" >/dev/null 2>"$tmp/err" \
  || die "ServiceAccount $VAULT_NS/$PROOF_SA is missing ($(first_err)); it comes with idp-gitops workloads/vault (sync the vault app). Then: $REBUILD"

for n in "$NS_A" "$NS_B"; do
  st="$(tns_state "$n")"
  case "$st" in
    absent) ;;
    ours | terminating) die "$n is a leftover of an earlier run ($st). Remove it with: $ME --cleanup" ;;
    foreign) die "$n already exists and was not created by this script: refusing to run (it will not be touched)" ;;
    *) die "could not check whether $n exists: $(first_err)" ;;
  esac
done
# Worst case of every wait while the admin token is needed (step 3: two TeamNamespaces, steps 5
# and 6, step 8: two deletions, the same two again in the cleanup) plus 15 min for overhead.
worst=$((2 * READY_TIMEOUT + SYNC_TIMEOUT + DENY_WAIT + 4 * DELETE_TIMEOUT + 900))
if [ "$worst" -gt "$PROOF_TOKEN_MAX" ]; then
  info "WARNING: with these PROOF_* timeouts a slow run can take ${worst}s, longer than the ${PROOF_TOKEN_MAX}s"
  info "the $PROOF_ROLE token lives; it then fails with a Vault 403 and lists what is left."
fi
info "WARNING: this creates the throwaway TeamNamespaces $NS_A and $NS_B and a Vault token of role"
info "$PROOF_ROLE (at most 1 h), and removes all of them again at the end."
ppass "preflight"

# --- 2. short-lived admin token -----------------------------------------------------------------
step "2. short-lived admin token (Kubernetes auth role $PROOF_ROLE as ServiceAccount $VAULT_NS/$PROOF_SA)"
# The JWT is only used for this one login, so it gets the shortest lifetime the API allows. It goes
# from kubectl's STDOUT through a pipe to a 0600 file and from there on STDIN to `jwt=-`.
if ! kubectl -n "$VAULT_NS" create token "$PROOF_SA" --audience vault --duration 10m 2>"$tmp/err" | tr -d '\n' >"$tmp/proof-jwt" \
  || [ ! -s "$tmp/proof-jwt" ]; then
  rm -f "$tmp/proof-jwt"
  die "could not get a token for ServiceAccount $VAULT_NS/$PROOF_SA (audience vault; needs create on serviceaccounts/token in namespace $VAULT_NS): $(first_err)"
fi
vexec_in sh -c "$VAULT_K8S_LOGIN_IN_POD" sh "$PROOF_ROLE" <"$tmp/proof-jwt" >"$tmp/admin.json" 2>"$tmp/err" || true
rm -f "$tmp/proof-jwt"
jq -j '.auth.client_token // ""' "$tmp/admin.json" >"$tmp/admin-token" 2>/dev/null || true
apol="$(jq -r '(.auth.token_policies // .auth.policies // []) | join(",")' "$tmp/admin.json" 2>/dev/null || true)"
attl="$(jq -r '.auth.lease_duration // 0' "$tmp/admin.json" 2>/dev/null || echo 0)"
rm -f "$tmp/admin.json"
if [ ! -s "$tmp/admin-token" ]; then
  rm -f "$tmp/admin-token"
  if grep -qi 'invalid role name' "$tmp/err" 2>/dev/null; then
    die "Vault has no Kubernetes auth role $PROOF_ROLE: $REBUILD"
  fi
  die "could not log in to Vault with role $PROOF_ROLE as $VAULT_NS/$PROOF_SA: $(first_err)"
fi
# A role that grants more than policy vault-proof is not what this script was reviewed against.
# The cleanup revokes the token.
[ "$apol" = "$PROOF_ROLE" ] || die "role $PROOF_ROLE issued a token with policies '$apol', expected only '$PROOF_ROLE': refusing to continue (vault read auth/kubernetes/role/$PROOF_ROLE)"
ppass "admin token: role and policy $PROOF_ROLE, TTL ${attl}s, not renewable (value not shown)"

# --- 3. throwaway TeamNamespaces ----------------------------------------------------------------
step "3. TeamNamespaces $NS_A and $NS_B (waiting up to ${READY_TIMEOUT}s each)"
for n in "$NS_A" "$NS_B"; do
  # Marked as created before `create`: the cleanup still checks the label, so it never deletes
  # an object it did not create.
  if [ "$n" = "$NS_A" ]; then CREATED_A=1; else CREATED_B=1; fi
  order="ORD-0000-$(printf '%06d' "$(($(od -An -N4 -tu4 /dev/urandom | tr -d ' \n') % 1000000))")"
  tns_yaml "$n" "$order" | kubectl create -f - >/dev/null 2>"$tmp/err" \
    || die "could not create TeamNamespace $n: $(first_err)"
done
for n in "$NS_A" "$NS_B"; do
  deadline=$((SECONDS + READY_TIMEOUT))
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "teamnamespace/$n" --timeout="$(remaining "$deadline")s" >/dev/null 2>&1 \
    || die "TeamNamespace $n did not become Ready (kubectl get teamnamespace $n -o yaml; kubectl -n idp-system logs deploy/idp-operator)"
  kubectl wait --for=condition=VaultReady "teamnamespace/$n" --timeout="$(remaining "$deadline")s" >/dev/null 2>&1 \
    || die "TeamNamespace $n has no VaultReady=True condition (kubectl get teamnamespace $n -o yaml)"
  until kubectl -n "$n" get serviceaccount/vault-reader vaultauth/vault-reader >/dev/null 2>&1; do
    [ "$SECONDS" -ge "$deadline" ] && die "namespace $n has no vault-reader ServiceAccount and VaultAuth"
    sleep "$POLL"
  done
done
ppass "$NS_A and $NS_B are Ready with VaultReady=True, ServiceAccount and VaultAuth vault-reader"

# --- 4. test values -----------------------------------------------------------------------------
# After VaultReady: the operator purges kv/<ns>/ before it reports VaultReady (purge-before-create).
step "4. write kv/$NS_A/hello and kv/$NS_B/hello (random values, not shown)"
for n in "$NS_A" "$NS_B"; do
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$tmp/value"
  [ -s "$tmp/value" ] || die "could not generate a random value"
  h="$(sha256 <"$tmp/value")"
  printf '{"data":{"message":"%s"}}' "$(<"$tmp/value")" >"$tmp/body"
  rm -f "$tmp/value"
  kv_left_add "$n/hello"
  vault_op "$tmp/admin-token" write "kv/data/$n/hello" "$tmp/body" >/dev/null 2>"$tmp/err" \
    || { rm -f "$tmp/body"; die "could not write kv/$n/hello with the admin token: $(first_err)"; }
  rm -f "$tmp/body"
  if [ "$n" = "$NS_A" ]; then HASH_A="$h"; else HASH_B="$h"; fi
done
[ "$(kv_hash "$NS_A")" = "$HASH_A" ] && [ "$(kv_hash "$NS_B")" = "$HASH_B" ] \
  || die "reading back kv/$NS_A/hello or kv/$NS_B/hello did not return the written value"
ppass "wrote and read back kv/$NS_A/hello and kv/$NS_B/hello"

# --- 5. positive proof --------------------------------------------------------------------------
step "5. positive: each namespace syncs its own kv/<ns>/hello (waiting up to ${SYNC_TIMEOUT}s)"
for n in "$NS_A" "$NS_B"; do
  vss_yaml "$n" hello "$n/hello" hello | kubectl create -f - >/dev/null 2>"$tmp/err" \
    || die "could not create VaultStaticSecret $n/hello: $(first_err)"
done
POS_A=""
POS_B=""
deadline=$((SECONDS + SYNC_TIMEOUT))
while :; do
  [ -z "$POS_A" ] && [ "$(k8s_hash "$NS_A" hello)" = "$HASH_A" ] && POS_A=1
  [ -z "$POS_B" ] && [ "$(k8s_hash "$NS_B" hello)" = "$HASH_B" ] && POS_B=1
  { [ -n "$POS_A" ] && [ -n "$POS_B" ]; } && break
  [ "$SECONDS" -ge "$deadline" ] && break
  sleep "$POLL"
done
for n in "$NS_A" "$NS_B"; do
  if [ "$n" = "$NS_A" ]; then ok="$POS_A"; want="$HASH_A"; p=P1; else ok="$POS_B"; want="$HASH_B"; p=P2; fi
  if [ -n "$ok" ]; then
    ppass "$p $n reads its own secret: Secret $n/hello key message matches kv/$n/hello by sha256"
  else
    got="$(k8s_hash "$n" hello)"
    if [ -z "$got" ]; then
      pfail "$p Secret $n/hello did not appear within ${SYNC_TIMEOUT}s (kubectl -n $n describe vaultstaticsecret hello; reason: $(warning_reason "$n" hello))"
    else
      pfail "$p Secret $n/hello holds a different value (sha256 ${got:0:12}... expected ${want:0:12}...)"
    fi
  fi
done

# --- 6. negative proof --------------------------------------------------------------------------
step "6. negative: a namespace cannot read the other one's path (watching ${DENY_WAIT}s)"
vss_yaml "$NS_A" hello-b "$NS_B/hello" hello-b | kubectl create -f - >/dev/null 2>"$tmp/err" \
  || die "could not create VaultStaticSecret $NS_A/hello-b: $(first_err)"
vss_yaml "$NS_B" hello-a "$NS_A/hello" hello-a | kubectl create -f - >/dev/null 2>"$tmp/err" \
  || die "could not create VaultStaticSecret $NS_B/hello-a: $(first_err)"
LEAK_A=""
LEAK_B=""
deadline=$((SECONDS + DENY_WAIT))
while [ "$SECONDS" -lt "$deadline" ]; do
  secret_exists "$NS_A" hello-b && LEAK_A=1
  secret_exists "$NS_B" hello-a && LEAK_B=1
  { [ -n "$LEAK_A" ] && [ -n "$LEAK_B" ]; } && break
  sleep "$POLL"
done
# negative_result <proof> <ns> <vss> <foreign ns> <leaked> <positive ok>
# PASS needs all of: the Secret never appeared, the positive proof in the same namespace passed
# (so VSO and the login work), and VSO's Warning shows that Vault denied the read (403).
negative_result() {
  local p="$1" n="$2" v="$3" f="$4" leaked="$5" pos="$6" reason
  if [ -n "$leaked" ] || secret_exists "$n" "$v"; then
    pfail "$p ISOLATION BROKEN: Secret $n/$v appeared, $n read kv/$f/hello"
    return 0
  fi
  reason="$(warning_reason "$n" "$v")"
  if [ -z "$reason" ]; then
    pfail "$p inconclusive: Secret $n/$v stayed absent, but VSO reported no Warning event for it (kubectl -n $n describe vaultstaticsecret $v)"
  elif ! denied_403 "$n" "$v"; then
    pfail "$p inconclusive: Secret $n/$v stayed absent, but VSO's Warning ($reason) does not show a Vault 403/permission denied (kubectl -n $n describe vaultstaticsecret $v)"
  elif [ -z "$pos" ]; then
    pfail "$p inconclusive: Secret $n/$v stayed absent (VSO: $reason, 403), but the positive proof in $n failed too"
  else
    ppass "$p $n cannot read kv/$f/hello: Secret $n/$v absent after ${DENY_WAIT}s, Vault answered 403 (VSO Warning reason: $reason)"
  fi
}
negative_result P3 "$NS_A" hello-b "$NS_B" "$LEAK_A" "$POS_A"
negative_result P4 "$NS_B" hello-a "$NS_A" "$LEAK_B" "$POS_B"

# --- 7. portal role is write-only ---------------------------------------------------------------
step "7. P7: Vault role $PORTAL_ROLE (portal Secrets page) is write-only"
# p7_try <want: denied|allowed> <op> <path> [<body>]: one attempt with the portal's Vault token.
# Sets P7_GOT (allowed|denied|error) and adds a line to P7_BAD when it is not what is wanted.
P7_BAD=""
p7_try() {
  local want="$1" op="$2" path="$3" body="${4:-}" rc
  vault_op "$tmp/portal-token" "$op" "$path" ${body:+"$body"} >/dev/null 2>"$tmp/err" && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    P7_GOT=allowed
  elif [ "$rc" != 10 ] && denied_err; then
    P7_GOT=denied
  else
    P7_GOT=error
  fi
  info "$op $path: $P7_GOT (want $want)"
  [ "$P7_GOT" = "$want" ] || P7_BAD="$P7_BAD; $op $path is $P7_GOT"
}
# p7_platform_write <ns>: writing under a platform prefix must be denied; if it was not, remove
# the key again with the same token (or hand it to the human).
p7_platform_write() {
  local k
  k="$1/vproof-p7-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  p7_try denied write "kv/data/$k" "$tmp/p7-body"
  if [ "$P7_GOT" = allowed ]; then
    vault_op "$tmp/portal-token" delete "kv/metadata/$k" >/dev/null 2>&1 || MANUAL_LEFT="$MANUAL_LEFT $k"
  fi
}
if vault_op "$tmp/admin-token" read "auth/kubernetes/role/$PORTAL_ROLE" >/dev/null 2>"$tmp/err"; then
  role_rc=0
else
  role_rc=$?
fi
if [ "$role_rc" = 2 ] && grep -q 'No value found' "$tmp/err"; then
  pskip "P7 role $PORTAL_ROLE does not exist yet (idp-gitops portal Secrets change not deployed): write-only check skipped"
elif [ "$role_rc" != 0 ]; then
  pfail "P7 could not read role $PORTAL_ROLE with the admin token: $(first_err)"
elif ! kubectl -n "$PORTAL_SA_NS" create token "$PORTAL_SA" --audience vault --duration 10m 2>"$tmp/err" | tr -d '\n' >"$tmp/portal-jwt" \
  || [ ! -s "$tmp/portal-jwt" ]; then
  rm -f "$tmp/portal-jwt"
  pfail "P7 could not get a token for ServiceAccount $PORTAL_SA_NS/$PORTAL_SA (audience vault): $(first_err)"
else
  # The ServiceAccount JWT goes on STDIN to `vault write auth/kubernetes/login jwt=-`; the Vault
  # token comes back on STDOUT into a 0600 file.
  vexec_in sh -c "$VAULT_K8S_LOGIN_IN_POD" sh "$PORTAL_ROLE" <"$tmp/portal-jwt" >"$tmp/portal-login.json" 2>"$tmp/err" || true
  rm -f "$tmp/portal-jwt"
  jq -j '.auth.client_token // ""' "$tmp/portal-login.json" >"$tmp/portal-token" 2>/dev/null || true
  rm -f "$tmp/portal-login.json"
  if [ ! -s "$tmp/portal-token" ]; then
    rm -f "$tmp/portal-token"
    pfail "P7 could not log in to Vault with role $PORTAL_ROLE as $PORTAL_SA_NS/$PORTAL_SA: $(first_err)"
  else
    printf '{"data":{"message":"vault-proof P7 write-only test"}}' >"$tmp/p7-body"
    p7_key="$NS_A/p7-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    p7_try denied read "kv/data/$NS_A/hello"
    kv_left_add "$p7_key"
    p7_try allowed write "kv/data/$p7_key" "$tmp/p7-body"
    p7_platform_write vault-demo
    p7_platform_write idp-system
    p7_try denied list "kv/metadata/"
    if [ "$P7_METADATA" = skip ]; then
      info "read/list on kv/metadata/$NS_A/ not checked (PROOF_P7_METADATA=skip)"
    else
      p7_try denied read "kv/metadata/$NS_A/hello"
      p7_try denied list "kv/metadata/$NS_A/"
    fi
    vault_op "$tmp/admin-token" delete "kv/metadata/$p7_key" >/dev/null 2>&1 && kv_left_del "$p7_key"
    vault_op "$tmp/portal-token" revoke-self - >/dev/null 2>&1 || true
    rm -f "$tmp/portal-token" "$tmp/p7-body"
    if [ -z "$P7_BAD" ]; then
      ppass "P7 role $PORTAL_ROLE is write-only: values$([ "$P7_METADATA" = skip ] || echo " and metadata") unreadable, platform paths and the kv/metadata/ root denied, writes to a tenant path allowed"
    else
      pfail "P7 role $PORTAL_ROLE is not write-only as designed${P7_BAD}"
    fi
  fi
fi

# --- 8. purge proof -----------------------------------------------------------------------------
step "8. purge: deleting a TeamNamespace removes its kv/<ns>/ only (waiting up to ${DELETE_TIMEOUT}s each)"
if delete_if_ours "$NS_A"; then
  CREATED_A=""
  sa="$(kv_state "$NS_A")"
  sb="$(kv_state "$NS_B")"
  hb="$(kv_hash "$NS_B")"
  [ "$sa" = gone ] && kv_left_drop_ns "$NS_A"
  if [ "$sa" = gone ] && [ "$sb" = present ] && [ "$hb" = "$HASH_B" ]; then
    ppass "P5 deleting $NS_A purged kv/$NS_A/ and left kv/$NS_B/hello intact"
  else
    pfail "P5 after deleting $NS_A: kv/$NS_A/ is $sa (want gone), kv/$NS_B/ is $sb (want present), kv/$NS_B/hello $([ "$hb" = "$HASH_B" ] && echo unchanged || echo 'changed or unreadable')"
  fi
else
  pfail "P5 TeamNamespace $NS_A or its namespace was not removed within ${DELETE_TIMEOUT}s (VaultPurgePending? kubectl get teamnamespace $NS_A -o yaml)"
fi
if delete_if_ours "$NS_B"; then
  CREATED_B=""
  sa="$(kv_state "$NS_A")"
  sb="$(kv_state "$NS_B")"
  [ "$sa" = gone ] && kv_left_drop_ns "$NS_A"
  [ "$sb" = gone ] && kv_left_drop_ns "$NS_B"
  if [ "$sa" = gone ] && [ "$sb" = gone ]; then
    ppass "P6 deleting $NS_B purged kv/$NS_B/; kv/$NS_A/ and kv/$NS_B/ are both gone"
  else
    pfail "P6 after deleting $NS_B: kv/$NS_A/ is $sa, kv/$NS_B/ is $sb (want both gone)"
  fi
else
  pfail "P6 TeamNamespace $NS_B or its namespace was not removed within ${DELETE_TIMEOUT}s (VaultPurgePending? kubectl get teamnamespace $NS_B -o yaml)"
fi

[ "$FAILED" = 0 ] || exit 1
exit 0
