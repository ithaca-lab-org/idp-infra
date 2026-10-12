#!/usr/bin/env bash
# Run by `make up` before applying envs/dev. Fails early, with a clear message,
# if the persistent stack (KMS key and the GKE service agent's grant) isn't in place;
# otherwise cluster creation fails late with an opaque KMS permission error.
set -euo pipefail
project="${PROJECT_ID:-project-324502ff-9928-4b17-a89}"
region="${REGION:-us-central1}"
number="$(gcloud projects describe "$project" --format='value(projectNumber)')"
agent="serviceAccount:service-${number}@container-engine-robot.iam.gserviceaccount.com"

policy="$(gcloud kms keys get-iam-policy gke-secrets --keyring=idp --location="$region" --project="$project" --format=json 2>/dev/null)" || {
  echo "precheck: KMS key idp/gke-secrets not found. Merge and apply envs/persistent first." >&2; exit 1; }

if ! grep -q "$agent" <<<"$policy"; then
  echo "precheck: $agent has no role on the KMS key. Re-apply envs/persistent." >&2; exit 1
fi

state="$(gcloud kms keys versions list --key=gke-secrets --keyring=idp --location="$region" --project="$project" --filter='state=ENABLED' --format='value(name)' | wc -l | tr -d ' ')"
if [ "$state" -lt 1 ]; then
  echo "precheck: no ENABLED version of the KMS key; cluster secrets would be unreadable." >&2; exit 1
fi
echo "precheck ok: KMS key and GKE agent grant present."
