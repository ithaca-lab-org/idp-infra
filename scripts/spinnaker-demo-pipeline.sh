#!/usr/bin/env bash
# Creates the hand-made Spinnaker application and pipeline for the first app (docs/order-04-first-app.md, ADR 0011):
# bake the app's Kustomize base from a git repo, then deploy it into the tenant namespace through the Clouddriver
# account `demo`. Milestone 1 only: milestone 2 replaces this with the DeliveryPipeline controller.
#
# Usage: ./scripts/spinnaker-demo-pipeline.sh --namespace demo --workload orders \
#          --repo https://github.com/ithaca-lab-org/sample-orders-api --ref main [--path deploy/base] [--account demo]
#        add --apply to create/update the application and pipeline, --run to trigger it (implies --apply)
#        Without --apply it only prints the JSON it would send (dry run).
#
# GATE_URL (default http://localhost:8084/api/v1): reach Gate with `kubectl -n spinnaker port-forward svc/gate 8084:8084`
# or the Tailscale Ingress (https://spinnaker-admin.<tailnet>.ts.net/api/v1). Gate has no login in this design (the
# network is the control, ADR 0011), so no credentials are sent.
#
# The image is NOT a parameter: the app repo's deploy/base names its image by digest (the CI workflow prints it), and
# --ref should be a commit SHA or a branch the Rosco bake can fetch (public repos only, anonymous account public-git).
# Application name (unverified until the first run: Spinnaker is believed to allow letters, digits, underscore and dot): "<namespace>_<workload>" with
# hyphens turned into underscores. Pipeline name: deploy.
# Needs curl and jq. Bash 3.2 compatible. Run by the human, never by the agent (it changes cluster state through Gate).
set -euo pipefail
set +x

GATE_URL="${GATE_URL:-http://localhost:8084/api/v1}"
NS="" WL="" REPO="" REF="" KPATH="deploy/base" ACCOUNT="demo" APPLY="no" RUN="no"

die() { printf 'spinnaker-demo-pipeline: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="${2:-}"; shift 2 ;;
    --workload) WL="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --path) KPATH="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --apply) APPLY="yes"; shift ;;
    --run) APPLY="yes"; RUN="yes"; shift ;;
    -h | --help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

for tool in curl jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"; done
[ -n "$NS" ] && [ -n "$WL" ] && [ -n "$REPO" ] && [ -n "$REF" ] || die "--namespace, --workload, --repo and --ref are required"
case "$NS$WL$ACCOUNT" in *[!a-z0-9-]*) die "namespace, workload and account must be lowercase letters, digits and hyphens" ;; esac
case "$REPO" in https://github.com/*) ;; *) die "--repo must be a public https://github.com/... repository" ;; esac
case "$KPATH" in /* | *..*) die "--path must be a relative path without .." ;; esac

APP="$(printf '%s_%s' "$NS" "$WL" | tr '-' '_')"

pipeline="$(jq -n --arg app "$APP" --arg ns "$NS" --arg acct "$ACCOUNT" --arg repo "$REPO" --arg ref "$REF" --arg path "$KPATH" '
  { application: $app, name: "deploy", keepWaitingPipelines: false, limitConcurrent: true, expectedArtifacts: [], triggers: [],
    stages: [
      { refId: "1", requisiteStageRefIds: [], type: "bakeManifest", name: "Bake kustomize",
        templateRenderer: "KUSTOMIZE", kustomizeFilePath: ($path + "/kustomization.yaml"), namespace: $ns, outputName: "app",
        expectedArtifacts: [ { id: "baked-app", displayName: "baked-app", usePriorArtifact: false, useDefaultArtifact: false,
          matchArtifact: { type: "embedded/base64", name: "app", artifactAccount: "embedded-artifact" } } ],
        inputArtifact: { account: "public-git", artifact: { type: "git/repo", artifactAccount: "public-git", reference: $repo, version: $ref } } },
      { refId: "2", requisiteStageRefIds: ["1"], type: "deployManifest", name: "Deploy", account: $acct, cloudProvider: "kubernetes",
        moniker: { app: $app }, source: "artifact", manifestArtifactAccount: "embedded-artifact", manifestArtifactId: "baked-app",
        namespaceOverride: $ns, skipExpressionEvaluation: false } ] }')"

app_task="$(jq -n --arg app "$APP" '{application: $app, description: "create application", job: [{type: "createApplication",
  application: {name: $app, email: "platform@example.com", cloudProviders: "kubernetes"}, user: "idp-demo"}]}')"

echo "spinnaker-demo-pipeline: application $APP, account $ACCOUNT, namespace $NS, repo $REPO @ $REF ($KPATH), Gate $GATE_URL"
if [ "$APPLY" != "yes" ]; then
  echo "--- dry run: pipeline JSON ---"
  jq . <<<"$pipeline"
  echo "--- dry run: nothing sent; add --apply to create it, --run to trigger it ---"
  exit 0
fi

gate() { curl -fsS -m 20 -H 'Content-Type: application/json' "$@"; }

if ! gate "$GATE_URL/applications/$APP" >/dev/null 2>&1; then
  gate -X POST -d "$app_task" "$GATE_URL/tasks" >/dev/null || die "cannot create the application (is Gate reachable at $GATE_URL?)"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    gate "$GATE_URL/applications/$APP" >/dev/null 2>&1 && break
    sleep 3
  done
  gate "$GATE_URL/applications/$APP" >/dev/null 2>&1 || die "application $APP did not appear"
  echo "  created application $APP"
else
  echo "  application $APP exists"
fi

id="$(gate "$GATE_URL/applications/$APP/pipelineConfigs" | jq -r '[.[] | select(.name == "deploy") | .id][0] // empty')"
if [ -n "$id" ]; then
  gate -X PUT -d "$(jq --arg id "$id" '. + {id: $id}' <<<"$pipeline")" "$GATE_URL/pipelines/$id" >/dev/null || die "cannot update the pipeline"
  echo "  updated pipeline deploy ($id)"
else
  gate -X POST -d "$pipeline" "$GATE_URL/pipelines" >/dev/null || die "cannot create the pipeline"
  echo "  created pipeline deploy"
fi

if [ "$RUN" = "yes" ]; then
  ref="$(gate -X POST -d '{"type":"manual","user":"idp-demo"}' "$GATE_URL/pipelines/$APP/deploy" | jq -r '.ref // empty')"
  [ -n "$ref" ] || die "could not trigger the pipeline"
  exid="${ref##*/}"
  echo "  triggered: execution $exid; waiting (up to about 3 minutes)"
  status="RUNNING"
  for _ in $(seq 1 22); do
    status="$(gate "$GATE_URL/pipelines/$exid" | jq -r '.status')"
    case "$status" in SUCCEEDED | TERMINAL | CANCELED | STOPPED) break ;; esac
    sleep 8
  done
  echo "  pipeline status: $status"
  gate "$GATE_URL/pipelines/$exid" | jq -r '.stages[] | "  - " + .name + ": " + .status'
  [ "$status" = "SUCCEEDED" ] || exit 1
fi
