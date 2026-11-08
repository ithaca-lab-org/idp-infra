#!/usr/bin/env bash
# Removes what the resource broker (ADR 0010) leaves behind in the project when the cluster is rebuilt:
# buckets of namespaces that no longer exist, and IAM bindings for their principals. `make down`
# destroys the cluster, the TeamNamespaces and the claims, but not buckets or bucket IAM.
#
# Usage: ./scripts/tenant-resources-cleanup.sh                dry run: reports what would be done
#        ./scripts/tenant-resources-cleanup.sh --delete       does it
#        --assume-cluster-gone   treat every namespace as gone WITHOUT asking the cluster (`make down` uses this
#                                right after the destroy). DANGER: an unreachable cluster is not a gone cluster.
#                                Never pass it while a cluster exists; the script refuses if the GKE cluster
#                                ($CLUSTER in $ZONE) still answers `gcloud container clusters describe`.
#
# Acts only when it knows which TeamNamespaces exist: `kubectl get teamnamespaces` succeeded, or
# --assume-cluster-gone was given. With an unreachable cluster and no flag it reports and does nothing.
#
# For each bucket of the project labelled idp-managed=true (name idp-*, same project number, in the same
# listing row; labelled with its owner namespace, label idp-namespace):
#   - owner namespace gone and the bucket EMPTY: deleted (--delete only; Cloud Storage refuses a non-empty bucket).
#   - owner namespace gone and NOT empty: reported as ORPHAN with the object count (listing needs read access,
#     which the human running this has). Never deleted.
#   - bindings whose member is principal://.../<this project's pool>/subject/ns/<ns>/sa/<x> of a namespace that
#     no longer exists are removed with ONE read-modify-write of the policy (etag-guarded); every other binding
#     and member stays as it was. Kept orphans are included. Conditional policies below version 3 are skipped.
#   - buckets labelled idp-releasing=true and updated in the last 10 minutes are skipped (the broker is working).
# Hard cap: more than 50 actions (deletions plus policy edits) in one run is refused as "something is off".
# Exit 0 for a dry run and for a clean run; 1 if an action failed. Bash 3.2 compatible. Needs gcloud and jq.
set -euo pipefail
set +x

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
MAX_ACTIONS=50
RELEASING_GRACE=600 # seconds

die() { printf 'tenant-resources-cleanup: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

mode="dry-run"
assume_gone="no"
for arg in "$@"; do
  case "$arg" in
    --delete) mode="delete" ;;
    --assume-cluster-gone) assume_gone="yes" ;;
    -h | --help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument '$arg' (see --help)" ;;
  esac
done

for tool in gcloud jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"; done

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tenant-resources-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

PNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
[ -n "$PNUM" ] || die "cannot describe project $PROJECT (authenticated? PROJECT_ID set?)"
POOL="$PROJECT.svc.id.goog"
PRE="principal://iam.googleapis.com/projects/$PNUM/locations/global/workloadIdentityPools/$POOL/subject/ns/"

# --- list the candidates (name, owner namespace, releasing, seconds since last update, seconds since creation) -------------
gcloud storage buckets list --project="$PROJECT" --raw --format=json >"$tmp/all.json" 2>"$tmp/err" \
  || die "cannot list the buckets of $PROJECT: $(head -n 1 "$tmp/err" | cut -c1-160)"
jq -e 'type == "array"' "$tmp/all.json" >/dev/null 2>&1 || die "unexpected bucket listing"
# Name, project number and idp-managed=true all come from the same row. Empty fields become "-"
# (read would collapse empty tab fields).
jq -r --arg n "$PNUM" '.[]
  | select((.name | test("^idp-[a-z0-9._-]+$"))
      and (((.labels // {})["idp-managed"]) == "true")
      and (((.projectNumber // "") | tostring) == $n))
  | [ .name,
      ((.labels["idp-namespace"] // "") | if test("^[a-z0-9-]{1,63}$") then . else "-" end),
      ((.labels["idp-releasing"] // "-")),
      (if .updated then ((now - ((.updated | sub("\\.[0-9]+"; "")) | fromdateiso8601)) | floor | tostring) else "-1" end),
      (if .timeCreated then ((now - ((.timeCreated | sub("\\.[0-9]+"; "")) | fromdateiso8601)) | floor | tostring) else "-1" end)
    ] | @tsv' "$tmp/all.json" >"$tmp/rows.tsv"
total="$(grep -c . "$tmp/rows.tsv" || true)"
echo "tenant-resources-cleanup: $total idp-managed bucket(s) in $PROJECT (project number $PNUM)"


# --- which namespaces exist (asked AFTER the listing, so a bucket created meanwhile is not misjudged) --
act="no"
LIVE_JSON="[]"
EXPECT_CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
if [ "$assume_gone" = "yes" ]; then
  # Proceed only on a definite "not found"; auth, network or wrong-zone errors are not proof of absence.
  if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>"$tmp/err"; then
    die "--assume-cluster-gone given but cluster $CLUSTER still exists in $ZONE: refusing (run without the flag to ask the cluster)"
  fi
  if ! grep -qiE 'NOT_FOUND|404|not found' "$tmp/err"; then
    die "cannot tell whether cluster $CLUSTER is gone ($(head -n 1 "$tmp/err" | cut -c1-140)): not a NOT_FOUND answer, so nothing is changed"
  fi
  act="yes"
  echo "tenant-resources-cleanup: --assume-cluster-gone: cluster $CLUSTER not found; treating every namespace as gone"
else
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "tenant-resources-cleanup: kubectl not found: NOTHING will be changed; listing only"
  elif [ "$ctx" != "$EXPECT_CTX" ]; then
    echo "tenant-resources-cleanup: kubectl context is '${ctx:-none}', expected '$EXPECT_CTX': NOTHING will be changed; listing only"
  elif kubectl get teamnamespaces.idp.ithaca-idp.com -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' >"$tmp/ns.txt" 2>"$tmp/err"; then
    LIVE_JSON="$(jq -R 'select(length > 0)' "$tmp/ns.txt" | jq -sc .)"
    nlive="$(jq 'length' <<<"$LIVE_JSON")"
    echo "tenant-resources-cleanup: cluster answered ($ctx): $nlive TeamNamespace(s) exist"
    if [ "$nlive" -eq 0 ] && [ "$total" -gt 0 ]; then
      echo "tenant-resources-cleanup: 0 TeamNamespaces but $total idp-managed bucket(s): looks like a fresh or wrong cluster, so NOTHING will be changed (use --assume-cluster-gone only after make down)"
    else
      act="yes"
    fi
  else
    echo "tenant-resources-cleanup: cannot ask the cluster for TeamNamespaces ($(head -n 1 "$tmp/err" 2>/dev/null | cut -c1-120)): an unreachable cluster is not a gone cluster, so NOTHING will be changed; listing only"
  fi
fi
# --- decide ------------------------------------------------------------------------------------
: >"$tmp/del.list"
: >"$tmp/pol.list"
kept=0 skipped=0 orphans=0
while IFS=$'\t' read -r name ns rel age cage; do
  [ -n "$name" ] || continue
  if [ "$cage" -lt 0 ] || [ "$cage" -lt "$RELEASING_GRACE" ]; then note "SKIP     $name: too new (created within the last 10 minutes), skipped"; skipped=$((skipped + 1)); continue; fi
  if [ "$ns" = "-" ]; then note "SKIP     $name: no valid idp-namespace label"; skipped=$((skipped + 1)); continue; fi
  if [ "$rel" = "true" ] && { [ "$age" -lt 0 ] || [ "$age" -lt "$RELEASING_GRACE" ]; }; then
    note "SKIP     $name: idp-releasing=true set within the last 10 minutes (the broker is working)"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$act" != "yes" ]; then note "SEEN     $name (owner $ns): not acting, namespaces unknown"; skipped=$((skipped + 1)); continue; fi
  if jq -e --arg ns "$ns" 'index($ns) != null' <<<"$LIVE_JSON" >/dev/null; then
    note "KEEP     $name (owner namespace $ns exists)"
    kept=$((kept + 1))
    printf '%s\t%s\n' "$name" "$ns" >>"$tmp/pol.list"
    continue
  fi
  # namespace gone: empty or not? The listing needs read access; any error means unknown, never delete.
  if ! gcloud storage objects list "gs://$name" --project="$PROJECT" --format='value(name)' --limit=1000 >"$tmp/objs.txt" 2>"$tmp/err"; then
    note "UNKNOWN  $name (owner $ns gone): cannot list objects ($(head -n 1 "$tmp/err" | cut -c1-100)); left alone"
    skipped=$((skipped + 1))
    printf '%s\t%s\n' "$name" "$ns" >>"$tmp/pol.list"
    continue
  fi
  n="$(grep -c . "$tmp/objs.txt" || true)"
  if [ "$n" -eq 0 ]; then
    note "EMPTY    $name (owner $ns gone): $([ "$mode" = delete ] && echo 'will be deleted' || echo 'would be deleted')"
    printf '%s\t%s\n' "$name" "$ns" >>"$tmp/del.list"
  else
    [ "$n" -lt 1000 ] || n="1000+"
    note "ORPHAN   $name (owner $ns gone): $n object(s); NOT deleted, a human decides (gcloud storage rm --recursive gs://$name)"
    orphans=$((orphans + 1))
    printf '%s\t%s\n' "$name" "$ns" >>"$tmp/pol.list"
  fi
done <"$tmp/rows.tsv"

# stale bindings: a jq program shared by the report and the rewrite
JQ_STALE='def stale: startswith($pre) and ((.[($pre | length):]) as $rest
  | ($rest | test("^[a-z0-9-]+/sa/[a-z0-9-]+$")) and (($live | index($rest | split("/sa/")[0])) == null));'
: >"$tmp/edit.list"
while IFS=$'\t' read -r name ns; do
  [ -n "$name" ] || continue
  gcloud storage buckets get-iam-policy "gs://$name" --project="$PROJECT" --format=json >"$tmp/pol-$name.json" 2>"$tmp/err" \
    || { note "UNKNOWN  $name: cannot read the IAM policy ($(head -n 1 "$tmp/err" | cut -c1-100))"; continue; }
  stale="$(jq -r --arg pre "$PRE" --argjson live "$LIVE_JSON" "$JQ_STALE"' [.bindings[]?.members[]? | select(stale)] | unique | .[]' "$tmp/pol-$name.json")" \
    || { note "UNKNOWN  $name: unexpected policy format"; continue; }
  [ -n "$stale" ] || continue
  if jq -e '([.bindings[]? | has("condition")] | any) and ((.version // 1) < 3)' "$tmp/pol-$name.json" >/dev/null; then
    note "SKIP     $name: stale binding(s) but the policy has conditions and version < 3 (editing could drop them)"
    skipped=$((skipped + 1))
    continue
  fi
  for m in $stale; do note "STALE    $name: binding for $m (namespace gone)"; done
  printf '%s\n' "$name" >>"$tmp/edit.list"
done <"$tmp/pol.list"

ndel="$(grep -c . "$tmp/del.list" || true)"
nedit="$(grep -c . "$tmp/edit.list" || true)"
actions=$((ndel + nedit))
if [ "$actions" -gt "$MAX_ACTIONS" ]; then
  printf 'tenant-resources-cleanup: %s actions (%s deletions, %s policy edits) exceed the safety cap of %s; refusing. Check the project and the cluster context by hand.\n' \
    "$actions" "$ndel" "$nedit" "$MAX_ACTIONS" >&2
  exit 2
fi

if [ "$mode" = "dry-run" ]; then
  echo "tenant-resources-cleanup: dry run, nothing changed. $ndel bucket(s) to delete, $nedit policy edit(s), $orphans orphan(s) with objects, $kept kept, $skipped skipped. Re-run with --delete to act."
  exit 0
fi

# --- act -----------------------------------------------------------------------------------------
deleted=0 edited=0 failed=0
while IFS=$'\t' read -r name ns; do
  [ -n "$name" ] || continue
  # Re-verify in a fresh read right before deleting: project, idp- prefix, idp-managed=true, owner label.
  if ! gcloud storage buckets describe "gs://$name" --project="$PROJECT" --raw --format=json >"$tmp/d.json" 2>"$tmp/err" \
    || ! jq -e --arg n "$PNUM" --arg ns "$ns" '(.name | test("^idp-[a-z0-9._-]+$")) and ((.projectNumber | tostring) == $n)
         and (((.labels // {})["idp-managed"]) == "true") and (((.labels // {})["idp-namespace"]) == $ns)
         and (((.labels // {})["idp-releasing"]) != "true")' "$tmp/d.json" >/dev/null 2>&1; then
    note "SKIP     $name: failed the re-check before deleting"
    failed=$((failed + 1))
    continue
  fi
  if gcloud storage buckets delete "gs://$name" --project="$PROJECT" --quiet >/dev/null 2>"$tmp/err"; then
    note "DELETED  $name"
    deleted=$((deleted + 1))
  else
    note "FAILED   deleting $name: $(head -n 1 "$tmp/err" | cut -c1-120)"
    failed=$((failed + 1))
  fi
done <"$tmp/del.list"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  # re-read (fresh etag), rewrite only the stale members, check the difference is exactly them, write once
  gcloud storage buckets get-iam-policy "gs://$name" --project="$PROJECT" --format=json >"$tmp/p0.json" 2>"$tmp/err" \
    || { note "FAILED   reading policy of $name"; failed=$((failed + 1)); continue; }
  jq --arg pre "$PRE" --argjson live "$LIVE_JSON" "$JQ_STALE"' .bindings = [ .bindings[]? | if (.members | any(stale)) then ((.members |= map(select(stale | not))) | select((.members | length) > 0)) else . end ]' \
    "$tmp/p0.json" >"$tmp/p1.json" || { note "FAILED   rewriting policy of $name"; failed=$((failed + 1)); continue; }
  if ! jq -en --argjson a "$(jq -c '[.bindings[]? | .role as $r | .members[]? | [$r, .]]' "$tmp/p0.json")" \
    --argjson b "$(jq -c '[.bindings[]? | .role as $r | .members[]? | [$r, .]]' "$tmp/p1.json")" \
    --arg pre "$PRE" --argjson live "$LIVE_JSON" "$JQ_STALE"' ($b - $a) == [] and (([$a[] | select((.[1] | stale) | not)] | sort) == ($b | sort)) and all(($a - $b)[]; .[1] | stale)' >/dev/null 2>&1; then
    note "FAILED   $name: the rewritten policy differs by more than the stale members; not written"
    failed=$((failed + 1))
    continue
  fi
  if gcloud storage buckets set-iam-policy "gs://$name" "$tmp/p1.json" --project="$PROJECT" >/dev/null 2>"$tmp/err"; then
    note "EDITED   $name: stale bindings removed"
    edited=$((edited + 1))
  else
    note "FAILED   writing policy of $name (etag changed meanwhile?): $(head -n 1 "$tmp/err" | cut -c1-120)"
    failed=$((failed + 1))
  fi
done <"$tmp/edit.list"

echo "tenant-resources-cleanup: deleted $deleted bucket(s), edited $edited policy(ies), $orphans orphan(s) with objects left for a human, $failed failure(s), $skipped skipped"
[ "$failed" -eq 0 ] || exit 1
