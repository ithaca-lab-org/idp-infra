#!/usr/bin/env bash
# Removes the Tailscale devices that cluster proxies leave behind in the tailnet.
#
# The Tailscale operator registers one device for itself and one per proxy (keycloak-admin,
# lldap-admin, ...). When the cluster is destroyed those devices stay in the tailnet, offline,
# and the next cluster's proxies get names with a -1, -2 suffix, which breaks KC_HOSTNAME_ADMIN.
#
# Usage: ./scripts/tailscale-cleanup.sh            dry run: lists what would be deleted
#        ./scripts/tailscale-cleanup.sh --delete   deletes the listed devices
#        --include-online     also delete devices that look online (default: skip). `make down` uses this
#                             right after a successful destroy, when the destroyed devices still look online.
#        --if-no-cluster      do nothing if the GKE cluster exists (`make up` uses this)
#
# Only devices that BOTH carry tag:k8s / tag:k8s-operator AND have one of this project's hostnames
# (TS_CLEANUP_HOSTNAMES, default: the operator, keycloak-admin, lldap-admin, each with an optional -N
# suffix) are touched. Add a hostname there when a new Tailscale Ingress is added. Uses the operator's existing OAuth client from Secret Manager; needs the scope
# "Devices Core: write" (docs/tailscale.md). Secret values never reach argv or stdout.
# `make down` runs it with --delete after a successful destroy.
set -euo pipefail
set +x # never trace: the values below must not reach the terminal or CI logs

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-idp}"
HOSTNAME_RE="${TS_CLEANUP_HOSTNAMES:-^(ithaca-idp-operator|keycloak-admin|lldap-admin)(-[0-9]+)?$}"
SM_CLIENT_ID="${TS_OAUTH_CLIENT_ID_SECRET:-tailscale-oauth-client-id}"
SM_CLIENT_SECRET="${TS_OAUTH_CLIENT_SECRET_SECRET:-tailscale-oauth-client-secret}"
API="https://api.tailscale.com/api/v2"
MAX_DELETE=50 # sanity cap: more matches than this means something is off

die() { printf 'tailscale-cleanup: %s\n' "$*" >&2; exit 1; }

mode="dry-run"
include_online="no"
only_if_no_cluster="no"
for arg in "$@"; do
  case "$arg" in
    --delete) mode="delete" ;;
    --include-online) include_online="yes" ;;
    --if-no-cluster) only_if_no_cluster="yes" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument '$arg' (see --help)" ;;
  esac
done

for tool in gcloud curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

if [ "$only_if_no_cluster" = "yes" ] && command -v gcloud >/dev/null 2>&1 \
   && gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
  echo "tailscale-cleanup: cluster $CLUSTER exists, leaving its devices alone"
  exit 0
fi

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tailscale-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

read_secret() { # read_secret <secret-manager-name> <output-file>
  gcloud secrets versions access latest --secret="$1" --project="$PROJECT" >"$2" 2>"$tmp/err" \
    || die "cannot read secret '$1': $(head -n 1 "$tmp/err")"
  [ -s "$2" ] || die "secret '$1' is empty"
}

read_secret "$SM_CLIENT_ID" "$tmp/id"
read_secret "$SM_CLIENT_SECRET" "$tmp/secret"

# OAuth client-credentials grant. The form body goes through a private file, not argv.
python3 - "$tmp" <<'PYEND'
import sys, urllib.parse
t = sys.argv[1]
body = urllib.parse.urlencode({
    "client_id": open(f"{t}/id").read().strip(),
    "client_secret": open(f"{t}/secret").read().strip(),
    "grant_type": "client_credentials",
})
open(f"{t}/form", "w").write(body)
PYEND
curl -sS --max-time 30 --data-binary @"$tmp/form" "$API/oauth/token" -o "$tmp/token.json" \
  || die "could not reach the Tailscale API"
python3 - "$tmp" <<'PYEND' || die "the OAuth token request was rejected (check the client id and secret in Secret Manager)"
import json, sys
t = sys.argv[1]
tok = json.load(open(f"{t}/token.json")).get("access_token")
if not tok:
    sys.exit(1)
open(f"{t}/auth", "w").write(f"Authorization: Bearer {tok}\n")
PYEND

curl -sS --max-time 30 -H @"$tmp/auth" "$API/tailnet/-/devices?fields=all" -o "$tmp/devices.json" \
  || die "could not list devices"
python3 - "$tmp" "$include_online" "$MAX_DELETE" "$HOSTNAME_RE" <<'PYEND'
import datetime, json, re, sys, time
t, include_online, cap, host_re = sys.argv[1], sys.argv[2] == "yes", int(sys.argv[3]), re.compile(sys.argv[4])
data = json.load(open(f"{t}/devices.json"))
if "devices" not in data:
    print("tailscale-cleanup: unexpected response from the Tailscale API (missing scope Devices Core?)", file=sys.stderr)
    sys.exit(2)
want_tags = {"tag:k8s", "tag:k8s-operator"}
id_re = re.compile(r"^[A-Za-z0-9]+$")
now = time.time()

def looks_online(d):
    # Anything we cannot prove is old counts as online: a parse problem must never make a live
    # device deletable.
    if d.get("connectedToControl") is True:
        return True
    ls = d.get("lastSeen")
    if not ls:
        return True
    try:
        clean = re.sub(r"\.\d+", "", ls).replace("Z", "+00:00")
        age = now - datetime.datetime.fromisoformat(clean).timestamp()
    except ValueError:
        return True
    return age < 300

rows, skipped = [], []
for d in data["devices"]:
    if not (want_tags & set(d.get("tags") or [])):
        continue
    if not host_re.match(str(d.get("hostname") or "")):
        continue
    if not id_re.match(str(d.get("id", ""))):
        print("tailscale-cleanup: a matching device has an unexpected id format; refusing", file=sys.stderr)
        sys.exit(4)
    (skipped if looks_online(d) and not include_online else rows).append(d)
for d in skipped:
    print(f"SKIP (online or unknown)  {d.get('name', '?')}")
for d in rows:
    print(f"candidate      {d.get('name', '?')}  last seen {d.get('lastSeen', 'never')}")
if len(rows) > cap:
    print(f"tailscale-cleanup: {len(rows)} matches exceed the safety cap of {cap}; refusing", file=sys.stderr)
    sys.exit(3)
open(f"{t}/ids", "w").write("\n".join(str(d["id"]) for d in rows) + ("\n" if rows else ""))
print(f"{len(rows)} device(s) match, {len(skipped)} skipped")
PYEND

n="$(grep -c . "$tmp/ids" || true)"
if [ "$mode" = "dry-run" ]; then
  echo "tailscale-cleanup: dry run, nothing deleted. Re-run with --delete to remove the ${n} listed device(s)."
  exit 0
fi

deleted=0
failed=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE -H @"$tmp/auth" "$API/device/$id" || true)"
  case "$code" in
    200|204|404) deleted=$((deleted + 1)) ;; # 404: already gone
    *)
      failed=$((failed + 1))
      echo "tailscale-cleanup: could not delete device $id (HTTP ${code:-none}); the OAuth client may lack 'Devices Core: write'" >&2
      ;;
  esac
done <"$tmp/ids"
echo "tailscale-cleanup: deleted ${deleted} device(s), ${failed} failure(s)"
[ "$failed" -eq 0 ] || exit 1
