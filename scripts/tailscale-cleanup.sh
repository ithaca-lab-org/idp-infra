#!/usr/bin/env bash
# Removes the Tailscale devices that cluster proxies leave behind in the tailnet.
#
# The Tailscale operator registers one device for itself and one per proxy (keycloak-admin,
# lldap-admin, ...). When the cluster is destroyed those devices stay in the tailnet, offline,
# and the next cluster's proxies get names with a -1, -2 suffix, which breaks KC_HOSTNAME_ADMIN.
#
# Usage: ./scripts/tailscale-cleanup.sh            dry run: lists what would be deleted
#        ./scripts/tailscale-cleanup.sh --delete   deletes the listed devices
#        --include-online                          also delete devices that are online now (default: skip)
#
# Only devices tagged tag:k8s or tag:k8s-operator are touched (the tags the operator gives its
# devices). Uses the operator's existing OAuth client from Secret Manager; needs the scope
# "Devices Core: write" (docs/tailscale.md). Secret values never reach argv or stdout.
# `make down` runs it with --delete after a successful destroy.
set -euo pipefail
set +x # never trace: the values below must not reach the terminal or CI logs

PROJECT="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
SM_CLIENT_ID="${TS_OAUTH_CLIENT_ID_SECRET:-tailscale-oauth-client-id}"
SM_CLIENT_SECRET="${TS_OAUTH_CLIENT_SECRET_SECRET:-tailscale-oauth-client-secret}"
API="https://api.tailscale.com/api/v2"
MAX_DELETE=50 # sanity cap: more matches than this means something is off

die() { printf 'tailscale-cleanup: %s\n' "$*" >&2; exit 1; }

mode="dry-run"
include_online="no"
for arg in "$@"; do
  case "$arg" in
    --delete) mode="delete" ;;
    --include-online) include_online="yes" ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument '$arg' (see --help)" ;;
  esac
done

for tool in gcloud curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

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
python3 - "$tmp" "$include_online" "$MAX_DELETE" <<'PYEND'
import json, sys, time, datetime
t, include_online, cap = sys.argv[1], sys.argv[2] == "yes", int(sys.argv[3])
data = json.load(open(f"{t}/devices.json"))
if "devices" not in data:
    print("tailscale-cleanup: unexpected response from the Tailscale API (missing scope Devices Core?)", file=sys.stderr)
    sys.exit(2)
want = {"tag:k8s", "tag:k8s-operator"}
now = time.time()

def online(d):
    if d.get("connectedToControl") is True:
        return True
    ls = d.get("lastSeen")
    if ls:
        try:
            age = now - datetime.datetime.fromisoformat(ls.replace("Z", "+00:00")).timestamp()
            return age < 300
        except ValueError:
            return False
    return False

rows, skipped = [], []
for d in data["devices"]:
    if want & set(d.get("tags") or []):
        (skipped if online(d) and not include_online else rows).append(d)
for d in skipped:
    print(f"SKIP (online)  {d.get('name','?')}")
for d in rows:
    print(f"candidate      {d.get('name','?')}  last seen {d.get('lastSeen','never')}")
if len(rows) > cap:
    print(f"tailscale-cleanup: {len(rows)} matches exceed the safety cap of {cap}; refusing", file=sys.stderr)
    sys.exit(3)
open(f"{t}/ids", "w").write("\n".join(str(d["id"]) for d in rows) + ("\n" if rows else ""))
print(f"{len(rows)} device(s) match, {len(skipped)} online device(s) skipped")
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
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE -H @"$tmp/auth" "$API/device/$id" || echo 000)"
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    deleted=$((deleted + 1))
  else
    failed=$((failed + 1))
    echo "tailscale-cleanup: could not delete device $id (HTTP $code); the OAuth client may lack 'Devices Core: write'" >&2
  fi
done <"$tmp/ids"
echo "tailscale-cleanup: deleted ${deleted} device(s), ${failed} failure(s)"
[ "$failed" -eq 0 ] || exit 1
