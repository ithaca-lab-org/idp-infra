#!/usr/bin/env bash
# Finds Persistent Disks that Kubernetes PersistentVolumeClaims left behind after `make down`. GKE does not
# delete dynamically provisioned disks when the cluster is destroyed, so they keep billing (and keep old data).
#
# Usage: ./scripts/pv-disk-cleanup.sh              report only (this is what `make down` runs)
#        ./scripts/pv-disk-cleanup.sh --delete     deletes the disks listed as ORPHAN
#
# A disk is an ORPHAN only if ALL of these hold:
#   - name starts with "pvc-" and its description carries GKE's marker kubernetes.io/created-for/pvc/name
#     (so hand-made disks and boot disks are never touched);
#   - it is attached to nothing (no `users`);
#   - the GKE cluster ($CLUSTER in $ZONE) is gone: `gcloud container clusters describe` answers NOT_FOUND.
#     While the cluster exists, or when the answer is anything else (auth, network), the script only reports.
# The report names the claim and namespace each disk was created for, so a human can tell the spinnaker spike's
# MySQL disk from anything else. Hard cap: more than 20 disks to delete in one run is refused ("something is off").
# Deleting a disk destroys its data; every PV on this platform is rebuilt by `make up`, but read the report first.
# Exit 0 for a report and a clean run; 1 if a delete failed. Bash 3.2 compatible. Needs gcloud and jq.
set -euo pipefail
set +x

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
MAX_DELETES=20

die() { printf 'pv-disk-cleanup: %s\n' "$*" >&2; exit 1; }

mode="report"
for arg in "$@"; do
  case "$arg" in
    --delete) mode="delete" ;;
    -h | --help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument '$arg' (see --help)" ;;
  esac
done

for tool in gcloud jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"; done

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pv-disk-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Is the cluster definitely gone?
cluster_gone="no"
if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>"$tmp/err"; then
  echo "pv-disk-cleanup: cluster $CLUSTER still exists in $ZONE: reporting only"
elif grep -qiE 'NOT_FOUND|404|not found' "$tmp/err"; then
  cluster_gone="yes"
else
  echo "pv-disk-cleanup: cannot tell whether cluster $CLUSTER is gone ($(head -n 1 "$tmp/err" | cut -c1-140)): reporting only"
fi

gcloud compute disks list --project="$PROJECT" --filter="name~^pvc-" --format=json >"$tmp/disks.json" 2>"$tmp/err" \
  || die "cannot list the disks of $PROJECT: $(head -n 1 "$tmp/err" | cut -c1-160)"
jq -e 'type == "array"' "$tmp/disks.json" >/dev/null 2>&1 || die "unexpected disk listing"

# name, zone, sizeGb, attached (yes/no), namespace, claim. The description is JSON written by GKE; anything
# that does not parse or lacks the marker is not a PVC disk for our purposes and is skipped.
jq -r '.[]
  | (.description // "" | (try fromjson catch {})) as $d
  | select($d["kubernetes.io/created-for/pvc/name"] != null)
  | [ .name,
      (.zone | split("/") | last),
      .sizeGb,
      (if ((.users // []) | length) > 0 then "yes" else "no" end),
      ($d["kubernetes.io/created-for/pvc/namespace"] // "-"),
      $d["kubernetes.io/created-for/pvc/name"]
    ] | @tsv' "$tmp/disks.json" >"$tmp/rows.tsv"

total="$(grep -c . "$tmp/rows.tsv" || true)"
echo "pv-disk-cleanup: $total PVC disk(s) in $PROJECT"
: >"$tmp/del.list"
while IFS=$'\t' read -r name zone size attached ns claim; do
  [ -n "$name" ] || continue
  if [ "$attached" = "yes" ]; then
    printf '  IN USE   %s (%s GB, %s) for %s/%s\n' "$name" "$size" "$zone" "$ns" "$claim"
  elif [ "$cluster_gone" = "yes" ]; then
    printf '  ORPHAN   %s (%s GB, %s) was %s/%s\n' "$name" "$size" "$zone" "$ns" "$claim"
    printf '%s\t%s\n' "$name" "$zone" >>"$tmp/del.list"
  else
    printf '  UNATTACHED, cluster not known to be gone: %s (%s GB, %s) for %s/%s\n' "$name" "$size" "$zone" "$ns" "$claim"
  fi
done <"$tmp/rows.tsv"

n="$(grep -c . "$tmp/del.list" || true)"
if [ "$n" -eq 0 ]; then
  echo "pv-disk-cleanup: nothing to delete"
  exit 0
fi
if [ "$mode" != "delete" ]; then
  echo "pv-disk-cleanup: $n orphan disk(s); run ./scripts/pv-disk-cleanup.sh --delete to remove them"
  exit 0
fi
[ "$n" -le "$MAX_DELETES" ] || die "$n disks to delete is more than the cap of $MAX_DELETES: something is off, nothing deleted"

failed=0
while IFS=$'\t' read -r name zone; do
  if gcloud compute disks delete "$name" --zone="$zone" --project="$PROJECT" --quiet >/dev/null 2>"$tmp/err"; then
    echo "  DELETED  $name"
  else
    echo "  FAILED   $name: $(head -n 1 "$tmp/err" | cut -c1-160)"
    failed=1
  fi
done <"$tmp/del.list"
exit "$failed"
