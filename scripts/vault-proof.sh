#!/usr/bin/env bash
# Proves on a running cluster that per-namespace Vault access works end to end and is isolated
# (idp-gitops workloads/vault/README.md, "Per-namespace access"; docs/vault.md, "Proving
# per-namespace isolation"). Run by a human from a laptop with gcloud and kubectl pointed at the
# cluster; it is not part of `make up` or CI.
#
# What it does (and undoes):
#   1. preflight: tools, Vault initialized and unsealed, operator VAULT_ENABLED=true, VSO objects;
#      refuses when TeamNamespaces/namespaces vproof-a or vproof-b already exist.
#   2. a short-lived admin token: `vault operator generate-root` with the recovery keys from Secret
#      Manager vault-recovery-keys; the root token is swapped at once for an orphan token with
#      policy vault-proof (only kv/vproof-a/ and kv/vproof-b/; TTL covers the worst-case run) and
#      revoked.
#   3. creates the throwaway TeamNamespaces vproof-a and vproof-b (label
#      idp.ithaca-idp.com/vault-proof=true) and waits for Ready, VaultReady and vault-reader.
#   4. writes kv/vproof-a/hello and kv/vproof-b/hello (random values, never shown).
#   5. P1/P2: a VaultStaticSecret in each namespace syncs its own value (compared by sha256).
#   6. P3/P4: a VaultStaticSecret pointing at the other namespace's path never syncs and VSO
#      reports that Vault denied it (403 / permission denied).
#   7. P7: the portal's Vault role portal-secrets is write-only (skipped if the role does not exist).
#   8. P5/P6: deleting a TeamNamespace purges its kv/<ns>/ and leaves the other one intact.
#   A PASS/FAIL line per proof and a summary. Cleanup (TeamNamespaces, KV leftovers, policy
#   vault-proof, the admin and portal tokens, an unfinished generate-root, the root token if it was
#   not revoked, temp files) runs on every exit, also on failure or Ctrl-C.
#
# Usage: ./scripts/vault-proof.sh            run the proof
#        ./scripts/vault-proof.sh --cleanup  remove leftovers of an interrupted run
#
# Secrets (recovery keys, OTP, root, admin and portal tokens, the test values) only live in 0600
# files in a private temp dir and in pipes: never in argv (so not in `ps`), env, stdout, stderr or
# logs. They reach vault-0 on `kubectl exec -i` STDIN only. Values are compared by sha256, never
# printed. Bash 3.2 compatible (macOS).
set -euo pipefail
set +x # never trace: tokens and keys pass through this script

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
VAULT_NS="vault"
VAULT_POD="vault-0"
SM_VAULT_RECOVERY="vault-recovery-keys"
NS_A="vproof-a"
NS_B="vproof-b"
MARK_KEY="idp.ithaca-idp.com/vault-proof"
MARK_JSONPATH='{.metadata.labels.idp\.ithaca-idp\.com/vault-proof}'
PROOF_POLICY_NAME="vault-proof"
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

# Admin token TTL: the worst case of every wait that can happen while it is needed (step 3: two
# TeamNamespaces, steps 5 and 6, step 8: two deletions, and the same two deletions again in the
# cleanup when step 8 timed out) plus 15 minutes for exec/kubectl overhead and P7; at least 45 min.
# The cleanup revokes it as soon as it is done, so a long TTL only matters if the script is killed.
ADMIN_TTL=$((2 * READY_TIMEOUT + SYNC_TIMEOUT + DENY_WAIT + 4 * DELETE_TIMEOUT + 900))
[ "$ADMIN_TTL" -ge 2700 ] || ADMIN_TTL=2700

# Policy of the admin token. Only the two proof namespaces, nothing else. In Vault ACL paths a `*`
# is a prefix glob only at the END of a path (anywhere else it is a literal character), so
# "kv/data/vproof-*/*" would match nothing: the namespaces are listed one by one instead. The
# metadata rules cover LIST kv/metadata/<ns>/ and DELETE kv/metadata/<ns>/<key>. Reading role
# portal-secrets tells P7 whether it exists; deleting its own policy lets the cleanup remove it.
PROOF_POLICY='path "kv/data/vproof-a/*" { capabilities = ["create", "update", "read", "delete"] }
path "kv/data/vproof-b/*" { capabilities = ["create", "update", "read", "delete"] }
path "kv/metadata/vproof-a/*" { capabilities = ["read", "list", "delete"] }
path "kv/metadata/vproof-b/*" { capabilities = ["read", "list", "delete"] }
path "auth/kubernetes/role/portal-secrets" { capabilities = ["read"] }
path "sys/policies/acl/vault-proof" { capabilities = ["delete"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }'

# Runs inside vault-0 (`sh -c`; the script text holds no secret). Arg: the TTL. STDIN: the ROOT
# token on the first line, then the policy. Refuses (14) if policy vault-proof exists with other
# content (someone else's), writes it, creates the admin token and revokes the root token. Why: the
# root token can do anything and must live for seconds only, so it never leaves this one exec after
# it is decoded; the proof itself runs on a token that can touch only kv/vproof-a/ and kv/vproof-b/
# and dies by itself even if this script is killed. It is an orphan so that revoking the root token
# (its parent) does not revoke it too. It keeps the default policy so that it can still revoke
# itself after the cleanup deleted policy vault-proof. The CLI's token helper file
# $HOME/.vault-token holds the root token for these few commands; the trap removes it.
# STDOUT: only the admin token JSON. Exit codes: 10 login, 11 policy write, 12 token create,
# 13 root revoke, 14 foreign policy, 15 policy read error.
VAULT_MINT_IN_POD='set -eu
umask 077
cleanup() { rm -f "$HOME/.vault-token"; }
trap cleanup EXIT
trap "exit 1" INT TERM HUP
IFS= read -r t || exit 10
printf "%s" "$t" | vault login -no-print - >/dev/null || exit 10
t=""
p="$(cat)"
if cur="$(vault policy read vault-proof 2>&1)"; then
  [ "$cur" = "$p" ] || exit 14
else
  case "$cur" in *"No policy named"*) ;; *) exit 15 ;; esac
fi
printf "%s\n" "$p" | vault policy write vault-proof - >/dev/null || exit 11
vault token create -orphan -policy=vault-proof -ttl="$1" -explicit-max-ttl="$1" -renewable=false -format=json || exit 12
vault token revoke -self >/dev/null || exit 13'

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
GENROOT_PENDING=""
POLICY_OURS=""
KEEP_ROOT=""
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

# decode_root_token <encoded-file> <otp-file> <out-file>: the encoded token is the raw (unpadded)
# standard base64 of root-token XOR OTP (Vault's roottoken.DecodeToken). Decoded here with shell
# builtins and pipes instead of `vault operator generate-root -decode=... -otp=...`, which would put
# both values in argv inside the pod.
decode_root_token() {
  local enc otp pad="" raw n i o v oct ch out=""
  local -a b
  enc="$(<"$1")"
  otp="$(<"$2")"
  case $((${#enc} % 4)) in 0) ;; 2) pad="==" ;; 3) pad="=" ;; *) return 1 ;; esac
  raw="$(printf '%s%s' "$enc" "$pad" | base64 --decode 2>/dev/null | od -An -v -tu1)" || return 1
  set -f
  # shellcheck disable=SC2206 # word splitting of od's numbers is intended
  b=($raw)
  set +f
  raw=""
  n=${#otp}
  [ "$n" -gt 0 ] && [ "${#b[@]}" -eq "$n" ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    printf -v o '%d' "'${otp:i:1}"
    v=$((b[i] ^ o))
    [ "$v" -ge 33 ] && [ "$v" -le 126 ] || return 1
    printf -v oct '%03o' "$v"
    printf -v ch "\\$oct"
    out="$out$ch"
    i=$((i + 1))
  done
  b=()
  [[ "$out" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s' "$out" >"$3"
  out=""
  otp=""
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

# Root token cleanup: revoke it; delete the file only after a confirmed revoke or when Vault says
# the token is not valid (any more). Otherwise KEEP the 0600 file and tell the human what to do.
cleanup_root() {
  local rc
  if [ -n "$POLICY_OURS" ]; then
    vault_op "$tmp/root-token" delete "sys/policies/acl/$PROOF_POLICY_NAME" >/dev/null 2>&1 && POLICY_OURS=""
  fi
  vault_op "$tmp/root-token" revoke-self - >/dev/null 2>"$tmp/err" && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$tmp/root-token"
    info "revoked the generated root token"
  elif [ "$rc" = 10 ] && denied_err; then
    rm -f "$tmp/root-token"
    info "the generated root token is not valid (already revoked)"
  else
    KEEP_ROOT=1
    pfail "cleanup: could NOT revoke the generated ROOT token; it may still be valid"
    printf '\n    !!!!! A VALID VAULT ROOT TOKEN MAY EXIST. It is kept (mode 0600) in:\n' >&2
    printf '    !!!!!   %s\n' "$tmp/root-token" >&2
    printf '    !!!!! Revoke it (token on stdin only), then delete the file and its directory:\n' >&2
    printf "    kubectl -n %s exec -i %s -- sh -c 'IFS= read -r t; printf %%s \"\$t\" | vault login -no-print - >/dev/null && vault token revoke -self; rc=\$?; rm -f \"\$HOME/.vault-token\"; exit \$rc' < '%s' && rm -f '%s' && rmdir '%s'\n" \
      "$VAULT_NS" "$VAULT_POD" "$tmp/root-token" "$tmp/root-token" "$tmp" >&2
    printf '    !!!!! If that fails too, rebuild Vault (docs/vault.md, "Rebuild Vault").\n\n' >&2
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
    if [ -n "$GENROOT_PENDING" ]; then
      if vexec vault operator generate-root -cancel >/dev/null 2>&1; then
        info "cancelled the unfinished generate-root attempt"
      else
        pfail "cleanup: could not cancel the generate-root attempt: kubectl -n $VAULT_NS exec $VAULT_POD -- vault operator generate-root -cancel"
      fi
    fi
    # Only present when minting the admin token failed before the root token was revoked.
    [ -s "$tmp/root-token" ] && cleanup_root
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
      if [ -n "$admin_ok" ] && vault_op "$tmp/admin-token" delete "sys/policies/acl/$PROOF_POLICY_NAME" >/dev/null 2>"$tmp/err"; then
        POLICY_OURS=""
        info "deleted policy $PROOF_POLICY_NAME"
      fi
      if vault_op "$tmp/admin-token" revoke-self - >/dev/null 2>&1; then
        info "revoked the admin token"
      else
        info "could not revoke the admin token (expired already?); it dies at its TTL anyway"
      fi
    else
      for k in $KV_LEFT; do MANUAL_LEFT="$MANUAL_LEFT $k"; done
    fi
    if [ -n "$POLICY_OURS" ]; then
      pfail "cleanup: policy $PROOF_POLICY_NAME is left in Vault (grants nothing without a token). With an admin token: vault policy delete $PROOF_POLICY_NAME"
    fi
    if [ -n "${MANUAL_LEFT// /}" ]; then
      pfail "cleanup: KV keys written by this run could not be removed (admin token expired or refused)"
      info "remove them with an admin token (docs/vault.md, 'Getting an admin token later'):"
      for k in $MANUAL_LEFT; do info "  vault kv metadata delete -mount=kv $k"; done
      info "(the operator also purges kv/$NS_A/ and kv/$NS_B/ whenever a TeamNamespace of that name is created or deleted)"
    fi
  fi
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    for k in "$tmp"/*; do
      [ -n "$KEEP_ROOT" ] && [ "$k" = "$tmp/root-token" ] && continue
      rm -f "$k" 2>/dev/null
    done
    [ -n "$KEEP_ROOT" ] || rmdir "$tmp" 2>/dev/null
  fi
  summary
  [ "$FAILED" = 0 ] && exit 0
  exit 1
}

# --- tools and temp dir -------------------------------------------------------------------------
tools="kubectl jq"
[ "$MODE" = proof ] && tools="kubectl gcloud jq base64 od awk"
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
  if gr="$(vexec vault operator generate-root -status -format=json 2>/dev/null)" \
    && [ "$(printf '%s' "$gr" | jq -r '.started' 2>/dev/null)" = true ]; then
    info "a generate-root attempt is in progress. If it is from an interrupted run of this script, cancel it:"
    info "  kubectl -n $VAULT_NS exec $VAULT_POD -- vault operator generate-root -cancel"
  fi
  info "KV data under kv/vproof-*/ is purged by the operator when a TeamNamespace is deleted. Policy"
  info "$PROOF_POLICY_NAME may be left in Vault (harmless; 'vault policy delete $PROOF_POLICY_NAME' with an"
  info "admin token). A leftover admin token expires by itself (TTL ${ADMIN_TTL}s)."
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
vthreshold="$(printf '%s' "$vstatus" | jq -r '.t // empty' 2>/dev/null || true)"
[ "$vinit" = true ] || die "Vault is not initialized or not reachable (vault status exit $vrc: $(first_err)); run ./scripts/bootstrap-secrets.sh"
[ "$vrc" = 0 ] && [ "$vsealed" = false ] || die "Vault is sealed (vault status exit $vrc); see docs/vault.md, Troubleshooting"
info "Vault is initialized and unsealed (recovery threshold ${vthreshold:-unknown})"

venabled="$(kubectl -n idp-system get deployment idp-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VAULT_ENABLED")].value}' 2>/dev/null || true)"
[ "$venabled" = true ] || die "the idp-operator does not run with VAULT_ENABLED=true (got '${venabled:-unset}'): per-namespace Vault access is off"
kubectl get crd teamnamespaces.idp.ithaca-idp.com vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1 \
  || die "CRD teamnamespaces.idp.ithaca-idp.com or vaultstaticsecrets.secrets.hashicorp.com is missing"
kubectl -n vault-secrets-operator get vaultconnection idp-vault >/dev/null 2>&1 \
  || die "VaultConnection vault-secrets-operator/idp-vault is missing (idp-gitops workloads/vault-secrets-operator)"
info "operator has VAULT_ENABLED=true; CRDs and VaultConnection vault-secrets-operator/idp-vault are present"

for n in "$NS_A" "$NS_B"; do
  st="$(tns_state "$n")"
  case "$st" in
    absent) ;;
    ours | terminating) die "$n is a leftover of an earlier run ($st). Remove it with: $ME --cleanup" ;;
    foreign) die "$n already exists and was not created by this script: refusing to run (it will not be touched)" ;;
    *) die "could not check whether $n exists: $(first_err)" ;;
  esac
done
gr_status="$(vexec vault operator generate-root -status -format=json 2>"$tmp/err")" \
  || die "could not read the generate-root status: $(first_err)"
[ "$(printf '%s' "$gr_status" | jq -r '.started' 2>/dev/null)" = false ] \
  || die "a generate-root attempt is already in progress (someone else, or a killed run). If it is yours: kubectl -n $VAULT_NS exec $VAULT_POD -- vault operator generate-root -cancel"
info "WARNING: this creates the throwaway TeamNamespaces $NS_A and $NS_B, Vault policy $PROOF_POLICY_NAME"
info "and an admin token (TTL ${ADMIN_TTL}s), and removes all of them again at the end."
ppass "preflight"

# --- 2. short-lived admin token -----------------------------------------------------------------
step "2. short-lived admin token (generate-root with the recovery keys; root revoked at once)"
gcloud secrets versions access latest --secret="$SM_VAULT_RECOVERY" --project="$PROJECT" >"$tmp/recovery.json" 2>"$tmp/err" \
  || die "could not read Secret Manager $SM_VAULT_RECOVERY in $PROJECT (needs roles/secretmanager.secretAccessor): $(first_err)"
nkeys="$(jq '.recovery_keys_b64 | length' "$tmp/recovery.json" 2>/dev/null || echo 0)"

# Pending from here: the cleanup cancels an attempt that does not complete.
GENROOT_PENDING=1
vexec vault operator generate-root -init -format=json >"$tmp/gr-init.json" 2>"$tmp/err" \
  || die "vault operator generate-root -init failed: $(first_err)"
nonce="$(jq -r '.nonce // ""' "$tmp/gr-init.json" 2>/dev/null || true)"
required="$(jq -r '.required // 0' "$tmp/gr-init.json" 2>/dev/null || echo 0)"
jq -j '.otp // ""' "$tmp/gr-init.json" >"$tmp/otp" 2>/dev/null || true
rm -f "$tmp/gr-init.json"
[[ "$nonce" =~ ^[A-Za-z0-9-]+$ ]] || die "generate-root -init returned no nonce"
[ -s "$tmp/otp" ] || die "generate-root -init returned no OTP"
[[ "$required" =~ ^[1-9][0-9]*$ ]] || die "generate-root -init returned no key threshold"
[[ "$nkeys" =~ ^[0-9]+$ ]] && [ "$nkeys" -ge "$required" ] \
  || die "$SM_VAULT_RECOVERY holds ${nkeys} recovery keys (JSON recovery_keys_b64), $required are needed"
i=0
while [ "$i" -lt "$required" ]; do
  # The key goes from Secret Manager's JSON through a pipe to vault's STDIN ("-").
  jq -j --argjson i "$i" '.recovery_keys_b64[$i]' "$tmp/recovery.json" \
    | vexec_in vault operator generate-root -nonce="$nonce" -format=json - >"$tmp/gr-step.json" 2>"$tmp/err" \
    || die "submitting recovery key $((i + 1)) of $required failed: $(first_err) (stale keys? only 'latest' of $SM_VAULT_RECOVERY matches this Vault)"
  i=$((i + 1))
done
rm -f "$tmp/recovery.json"
[ "$(jq -r '.complete' "$tmp/gr-step.json" 2>/dev/null)" = true ] || die "generate-root did not complete after $required keys"
jq -j 'if (.encoded_token // "") != "" then .encoded_token else (.encoded_root_token // "") end' "$tmp/gr-step.json" >"$tmp/encoded" 2>/dev/null || true
rm -f "$tmp/gr-step.json"
GENROOT_PENDING=""
decode_root_token "$tmp/encoded" "$tmp/otp" "$tmp/root-token" || { rm -f "$tmp/encoded" "$tmp/otp"; die "could not decode the generated root token (the attempt completed; the root token is valid but held by nobody: rebuild Vault to be safe)"; }
rm -f "$tmp/encoded" "$tmp/otp"

{
  cat "$tmp/root-token"
  printf '\n%s\n' "$PROOF_POLICY"
} | vexec_in sh -c "$VAULT_MINT_IN_POD" sh "${ADMIN_TTL}s" >"$tmp/admin.json" 2>"$tmp/err" && rc=0 || rc=$?
# Policy vault-proof was written by this run (so the cleanup may delete it) for 0, 12 and 13.
case "$rc" in 0 | 12 | 13) POLICY_OURS=1 ;; esac
# On failure $tmp/root-token stays: the cleanup revokes the root token with it (and keeps the file
# if that cannot be confirmed).
case "$rc" in
  0) rm -f "$tmp/root-token" ;;
  10) die "could not log in with the generated root token: $(first_err)" ;;
  11) die "could not write policy $PROOF_POLICY_NAME: $(first_err)" ;;
  12) die "could not create the admin token: $(first_err)" ;;
  13) die "could not revoke the generated root token: $(first_err)" ;;
  14) die "policy $PROOF_POLICY_NAME already exists in Vault with content this script did not write: refusing to overwrite it (inspect it with an admin token: vault policy read $PROOF_POLICY_NAME)" ;;
  15) die "could not check whether policy $PROOF_POLICY_NAME exists" ;;
  *) die "the admin token step in $VAULT_POD failed (exit $rc): $(first_err)" ;;
esac
jq -j '.auth.client_token // ""' "$tmp/admin.json" >"$tmp/admin-token" 2>/dev/null || true
rm -f "$tmp/admin.json"
[ -s "$tmp/admin-token" ] || die "no admin token in the token create output (the root token was revoked)"
ppass "admin token: orphan, policy $PROOF_POLICY_NAME, TTL ${ADMIN_TTL}s; root token revoked (values not shown)"

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
