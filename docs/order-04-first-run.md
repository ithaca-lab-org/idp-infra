# Order #04 milestone 1: first run (runbook, human steps)

Plan: `docs/order-04-first-app.md`. Design: ADR 0011. Everything below is run by the human; the agent can run the read-only checks and the API calls of the pipeline script when asked.

## What is deployed by Argo CD after `make up` (all merged to `main`)

- idp-gitops `apps/spinnaker.yaml` (wave 13): Spinnaker 2026.4.1 (base pinned by commit, images by digest), Gate and Clouddriver WITHOUT authentication behind a default-deny NetworkPolicy, Kubernetes account `demo` limited to namespace `demo`, ClusterRole `idp-spinnaker-deployer`, admission policy `idp-spinnaker-scope`. About 4 GiB: the node pool adds a second node.
- idp-gitops `apps/spinnaker-admin-access.yaml` (wave 14): Tailscale Ingress `spinnaker-admin` for Deck and Gate (platform admins on the tailnet only).
- idp-operator at idp-portal `ba7a747`: a `WorkloadIdentity` HTTPRoute sends traffic to Service `<workload>` port 80; each TeamNamespace gets RoleBinding `spinnaker-deployer` (Clouddriver to `idp-spinnaker-deployer`); `spinnaker` and `keycloak` are reserved namespace names; policy `idp-tenant-services` refuses ExternalName, LoadBalancer, NodePort and externalIPs Services in tenant namespaces.

## Steps

1. `cd idp-infra && git checkout main && git pull`, `time make up`, `./scripts/verify.sh`. verify.sh's smoke TeamNamespace goes through the new policies: if it fails, paste the message (it is the fix list). Then watch `kubectl -n spinnaker get pods -w` until everything is Ready (the second node must join first).
2. Portal (`https://portal.apps.ithaca-idp.com`, login `user01`..`user07`): order namespace `demo`, wait COMPLETE; Workloads page: workload `orders`; Secrets page: secret `orders-config` with keys `ORDERS_API_KEY` and `ORDERS_GREETING` (the Secret `orders-config` appears in `demo` through VSO; check `kubectl -n demo get secret orders-config`). Check the RoleBinding: `kubectl -n demo get rolebinding spinnaker-deployer`.
3. Restart Clouddriver ONCE now that `demo` exists (account changes apply only after a restart, ADR 0011 spike 2): `kubectl -n spinnaker rollout restart deploy/clouddriver`, wait about a minute. Check the account: through Gate, `GET /credentials` lists `demo`.
4. Sample app: repo `https://github.com/ithaca-lab-org/sample-orders-api` (public, created 2026-11-14). The first image is built and pinned: `ghcr.io/ithaca-lab-org/sample-orders-api@sha256:715f2adf1597b5deb5ec40c55c9893863d9107066d05267ee4a439964e59a7ec` (from commit 75d938f), `main` is at `83dd24de569c51e91f005988b73aef33ca9fcbbd` (use that as `--ref`). **One manual step before the first run: the GHCR package is private by default** (an anonymous pull answered 403 on 2026-11-14), so make it public: GitHub > ithaca-lab-org > Packages > sample-orders-api > Package settings > Change visibility > Public (it cannot be set through the API with the default token). Check: `curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:ithaca-lab-org/sample-orders-api:pull' | jq -r .token)" -H 'Accept: application/vnd.oci.image.index.v1+json' https://ghcr.io/v2/ithaca-lab-org/sample-orders-api/manifests/83dd24de569c51e91f005988b73aef33ca9fcbbd` must not be 403/401 (use the tag of the commit whose image you want; the digest is what the Deployment names). To ship a new version: push code, read the digest from the image workflow job summary, put it in `deploy/base/deployment.yaml` by PR, run the pipeline with the new commit SHA.
5. Reach Gate: `kubectl -n spinnaker port-forward svc/gate 8084:8084` (or the Tailscale host), then `./scripts/spinnaker-demo-pipeline.sh --namespace demo --workload orders --repo https://github.com/ithaca-lab-org/sample-orders-api --ref 83dd24de569c51e91f005988b73aef33ca9fcbbd` (dry run), then add `--run`.
6. Browse: `https://orders.demo.apps.ithaca-idp.com` (the wildcard certificate gains `*.demo.apps...` about 5 minutes after the namespace exists; the staging CA is not trusted by browsers). Expected: HTTP 200 with the app's JSON (secret keys reported as set, never their values).
7. Deck: `https://spinnaker-admin.<tailnet>.ts.net/` (needs the proxy device up): application `demo_orders`, Pipelines tab shows the run; Infrastructure shows the Deployment, ReplicaSet, Pods and Service.

## Things that are expected to need debugging (never exercised before)

- The route has never carried real traffic: the NetworkPolicy allow for TCP 15008 from the ingress gateway, the ambient AuthorizationPolicy, and whether the Gateway answers 500 while the Service is missing.
- The Tailscale Ingress: whether the proxy forwards `/api/v1` unchanged to Gate (if Deck loads but shows API errors, Gate needs its own host/Ingress); Deck with `authEnabled = false` and `gateUrl` from `window.location.origin`.
- Application name `demo_orders`: Spinnaker's naming rules are unverified.
- The admission policy `idp-spinnaker-scope`: a pipeline Deployment must set `serviceAccountName: orders` and the pod label `idp.ithaca-idp.com/workload: orders`, or the deploy is refused with that message.
- A deploy before step 3 fails with `wrongNamespace` or a missing account.

## Cleanup

`make down` (as usual; it prints orphaned PVC disks, `make pv-disk-cleanup DELETE=1 MAX=n` removes them). Everything above is rebuilt by the next `make up`; the namespace, workload, secret and pipeline must be ordered again.
