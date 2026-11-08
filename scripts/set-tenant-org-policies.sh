#!/usr/bin/env bash
# Enforce the two bucket guardrails for the tenant-resources broker (ADR 0010):
#   storage.publicAccessPrevention      -> no bucket in the project can be made public
#   storage.uniformBucketLevelAccess    -> no bucket ACLs, IAM only
# Usage: bash set-tenant-org-policies.sh [project-id]   (or PROJECT_ID=... , or answer the prompt)
set -euo pipefail

PAUSE_SECONDS=2

PROJECT_ID="${1:-${PROJECT_ID:-}}"
if [ -z "$PROJECT_ID" ]; then
  default_project="$(gcloud config get-value project 2>/dev/null || true)"
  read -r -p "Project ID [${default_project}]: " PROJECT_ID
  PROJECT_ID="${PROJECT_ID:-$default_project}"
fi
if [ -z "$PROJECT_ID" ]; then
  echo "No project ID given." >&2
  exit 1
fi

printf '\nThis enables the Organization Policy API and enforces two storage constraints on project: %s\n' "$PROJECT_ID"
read -r -p "Type yes to continue: " answer
if [ "$answer" != "yes" ]; then
  echo "Aborted, nothing was changed."
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -f "$tmp/pap.yaml" "$tmp/ubla.yaml"; rmdir "$tmp" 2>/dev/null || true' EXIT

printf 'name: projects/%s/policies/storage.publicAccessPrevention\nspec:\n  rules:\n  - enforce: true\n' "$PROJECT_ID" > "$tmp/pap.yaml"
printf 'name: projects/%s/policies/storage.uniformBucketLevelAccess\nspec:\n  rules:\n  - enforce: true\n' "$PROJECT_ID" > "$tmp/ubla.yaml"

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
pause() { printf '       waiting %s seconds...\n' "$PAUSE_SECONDS"; sleep "$PAUSE_SECONDS"; }

step "1/3 enabling orgpolicy.googleapis.com"
gcloud services enable orgpolicy.googleapis.com --project="$PROJECT_ID"
ok "orgpolicy.googleapis.com is enabled on $PROJECT_ID"
pause

step "2/3 gcloud org-policies set-policy storage.publicAccessPrevention"
gcloud org-policies set-policy "$tmp/pap.yaml"
ok "storage.publicAccessPrevention is enforced on $PROJECT_ID"
pause

step "3/3 gcloud org-policies set-policy storage.uniformBucketLevelAccess"
gcloud org-policies set-policy "$tmp/ubla.yaml"
ok "storage.uniformBucketLevelAccess is enforced on $PROJECT_ID"

printf '\nAll commands succeeded. Still to do by hand: the member allow-list (below) and the verification step.\n'
