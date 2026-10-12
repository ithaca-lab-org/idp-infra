# Istio ambient smoke test (GKE Standard + Dataplane V2)

Script: [`scripts/smoke-ambient.sh`](../scripts/smoke-ambient.sh). Human-run only, on a `make up` cluster.

## Purpose

Prove, before ADR 0002 and before Istio goes into `idp-gitops`, that Istio **ambient** mode works on this
cluster: GKE Standard, zonal, **Dataplane V2** (`ADVANCED_DATAPATH`, Cilium/eBPF), Gateway API standard
channel (GKE owns the Gateway API CRDs), private Spot nodes, Workload Identity and Cloud NAT.

The main risk is Dataplane V2. Its eBPF service handling (socket-level load balancing, "socketLB") could
send pod-to-ClusterIP traffic around istio-cni's in-pod redirection. If that happens, ztunnel never sees
the traffic and L4 policy silently stops being enforced. **Check 3 is the deciding check for that.**
Checks 4 and 5 then test that Kubernetes NetworkPolicy and an L7 waypoint also work alongside ambient.

## Prerequisites

| Tool | Notes |
|---|---|
| `gcloud` | Recent enough for `get-credentials --dns-endpoint` (396.0.0 was too old; run `gcloud components update`) |
| `gke-gcloud-auth-plugin` | `gcloud components install gke-gcloud-auth-plugin` |
| `kubectl` | Within one minor version of the cluster |
| `helm` | v3 (`helm upgrade --install --wait`, `helm uninstall --wait`) |
| `istioctl` | **Same version as `ISTIO_VERSION` in the script** (currently `1.27.1`). Optional: without it, check 2 relies on ztunnel logs only |
| `bash` | macOS `/bin/bash` 3.2 is fine |

The cluster also needs these, all already in `modules/gke` and `modules/network`:
- **Cloud NAT** so private nodes can pull from `docker.io`, `registry.k8s.io` and the Istio chart/image
  registries.
- The **`idp-master-webhooks` firewall** (TCP 15017 from the master range) so the API server can reach
  istiod's webhook.

Budget: at least 1 Spot e2-standard-4 node. istiod's default requests are large (UNVERIFIED: about 500m CPU
and 2 GiB), and Istio uses roughly one node's worth of headroom. With 2+ nodes, the echo pods prefer a
different node from the clients, so traffic crosses two ztunnels.

## Run order

```bash
cd idp-infra
make up                                   # human only; ~20-30 min
gcloud container clusters get-credentials idp --dns-endpoint \
  --zone us-central1-a --project project-324502ff-9928-4b17-a89
kubectl get nodes                         # Spot nodes Ready
istioctl version --remote=false           # must match ISTIO_VERSION in the script

./scripts/smoke-ambient.sh install        # ~3-6 min; idempotent
./scripts/smoke-ambient.sh deploy         # ~1-2 min; idempotent
./scripts/smoke-ambient.sh test 2>&1 | tee /tmp/smoke-ambient-$(date +%Y%m%d-%H%M).log
#   exit 0 = all PASS, 1 = at least one FAIL. Safe to re-run.

./scripts/smoke-ambient.sh cleanup        # optional, asks for 'yes' (or: cleanup --yes)
make down                                 # always; ~9 min
```

Keep the log outside the repo. It contains pod IPs and node names. Don't commit it.

Every subcommand can be re-run. `install` uses `helm upgrade --install`. `deploy` uses `kubectl apply`. At the
start of every run, `test` resets its own objects to a baseline by **re-applying** them: an allow-all
AuthorizationPolicy, an allow-all NetworkPolicy, and the `istio.io/use-waypoint` label removed from Service
`echo`. It never deletes anything. Only `cleanup` deletes.

Timeouts are environment variables listed at the top of the script, for example
`POLL_TIMEOUT=180 ./scripts/smoke-ambient.sh test` on a slow cluster. Defaults:
- helm 10m, rollout/wait 300s, kubectl request 30s
- curl 3s to connect / 5s total
- policy polling 90s every 3s, then 3 identical results in a row
- baseline settle 10s, probe settle 30s

## What `deploy` creates

Namespace `ambient-smoke`, labelled `istio.io/dataplane-mode=ambient`:

| Workload | ServiceAccount | Image | Role |
|---|---|---|---|
| `client` | `client` | `curlimages/curl:8.10.1` | Allowed caller |
| `client-other` | `client-other` | `curlimages/curl:8.10.1` | Must be denied |
| `echo` + Service `echo:80 -> 8080` | `echo` | `registry.k8s.io/e2e-test-images/agnhost:2.53` (`netexec`) | Target; `/hostname` returns the pod name |
| `echo-v2` + Service `echo-v2:80 -> 8080` | `echo-v2` | same | Control target (check 3) and L7 route target (check 5) |

## The checks

| # | What it does | What a PASS proves | PASS criteria |
|---|---|---|---|
| 1 | Inspects every app pod and every node | Ambient adds no sidecar. Pods are enrolled. The node-level data plane runs everywhere | Every app pod has exactly 1 container (shown as 1/1 Ready), no `istio-proxy`/`istio-init`/`istio-validation`, and annotation `ambient.istio.io/redirection=enabled`. Every node has a Ready `ztunnel` and a Ready `istio-cni-node` pod |
| 2 | `client` curls `http://echo.ambient-smoke.svc.cluster.local/hostname`; `client-other` does too, as a baseline | ClusterIP + DNS works and the traffic is in the mesh | HTTP 200 with a body starting `echo-`, for both clients. **Plus** at least one piece of ztunnel evidence: every pod listed with protocol `HBONE` in `istioctl ztunnel-config workloads`, **or** a ztunnel `connection complete` log line on echo's node from `.../ns/ambient-smoke/sa/client` |
| 3 | **DECISIVE.** Applies L4 `AuthorizationPolicy echo-l4` (ALLOW, principal `cluster.local/ns/ambient-smoke/sa/client`, selector `app=echo`) | ztunnel intercepts ClusterIP traffic under Dataplane V2 and enforces identity-based policy | Control first: `client-other -> echo-v2` succeeds. Then `client -> echo` succeeds, and `client-other -> echo` is denied (curl reset/timeout) within 90 s, then stays denied 3 times |
| 4 | Applies `NetworkPolicy echo-ingress`. It allows ingress to echo only on TCP **15008** (HBONE) from anywhere, plus TCP **8080** from **169.254.7.127/32** only | Dataplane V2 NetworkPolicy and ambient work together. Mesh traffic arrives only as HBONE. Kubelet probes still pass via the istio-cni probe SNAT address | `client -> echo` succeeds. `client-other -> echo` is still denied. After 30 s, echo is still Ready |
| 5 | Creates the `Gateway waypoint` (`gatewayClassName: istio-waypoint`, listener 15008/HBONE). Waits for `Programmed`. Updates `echo-l4` to also allow the waypoint's ServiceAccount. Labels Service `echo` with `istio.io/use-waypoint=waypoint`. Applies `HTTPRoute echo-header-route` (parent: Service `echo`; header `x-smoke-route: v2` routes to `echo-v2`, everything else to `echo`) | L7 routing through a per-namespace waypoint works with GKE's own Gateway API CRDs | Gateway is Programmed. Requests with the header return `echo-v2-...` (within 90 s, then 3 times in a row). Requests without it return `echo-...` (not `echo-v2`) 3 times in a row |

Notes on the checks:
- Why check 5 changes the policy: once a waypoint is in the path, echo's ztunnel sees the waypoint's
  identity instead of `client`'s, so the L4 policy has to allow it. As a result, during and after check 5,
  `client-other` can reach echo **through the waypoint**. Locking that down needs a waypoint-targeted
  (`targetRefs`) policy, which is out of scope here.
- The script labels the **Service** (not the namespace) with `use-waypoint`. That keeps checks 1-4 pure L4
  on every re-run.
- Check numbering follows the task brief, items (1)-(5). The brief's "checks 3-6" wording does not match its
  own list. Here, "check 3" is the decisive policy-bypass check and "check 4" is the NetworkPolicy check.

## Expected output (all passing)

Abridged. Timestamps go to stderr; `CHECK` lines and the summary go to stdout.

```
CHECK 1 PASS: all 4 app pods are 1/1 with no istio-proxy, enrolled in ambient; ztunnel and istio-cni Ready on every node
CHECK 2 PASS: client -> echo HTTP 200 via ClusterIP DNS; ztunnel evidence: istioctl ztunnel-config (all pods HBONE) + ztunnel log on ztunnel-xxxxx
CHECK 3 PASS: client allowed, client-other denied by ztunnel: ClusterIP traffic is intercepted and policy-enforced
CHECK 4 PASS: with HBONE-only NetworkPolicy: client allowed, client-other denied, echo stays Ready
CHECK 5 PASS: waypoint Programmed; 'x-smoke-route: v2' routed to echo-v2, no header routed to echo (L7 handled by the waypoint)

===== SUMMARY (Istio 1.27.1) =====
...
RESULT: PASS
```

## Pass/fail criteria for the whole run

- **PASS:** all 5 checks pass and the exit code is 0. Ambient is viable on this cluster as built, so write
  ADR 0002 with ambient as the mesh mode.
- **Hard FAIL:** check 3 fails with "client-other REACHED echo". Stop. Use the decision table below.
- **Soft FAIL:** check 1, 2 or 5 fails for an installation reason, e.g.:
  - an image pull failed
  - the chart version doesn't support the cluster's Kubernetes version
  - GatewayClass `istio-waypoint` is missing
  - GKE's Gateway API CRD version is too old for this Istio

  Fix it and re-run `test`. These don't count against ambient until they're understood.
- **Spot caveat:** a preemption in the middle of a run can fail any check. Re-run before drawing a
  conclusion. `kubectl get events -A | grep -i preempt` shows whether one happened.

## What to paste back for analysis

1. The whole `test` log (`/tmp/smoke-ambient-*.log`).
2. `helm list -n istio-system` and `istioctl version`.
3. `kubectl version` and `kubectl get nodes -o wide`.
4. `kubectl -n ambient-smoke get pods -o wide` and `kubectl -n istio-system get pods -o wide`.
5. `istioctl ztunnel-config workloads -i istio-system | grep ambient-smoke` and
   `istioctl ztunnel-config services -i istio-system | grep ambient-smoke`.
6. On echo's node: `kubectl -n istio-system logs <ztunnel-pod> --since=15m`.
7. If check 5 failed:
   - `kubectl -n ambient-smoke get gateway,httproute -o yaml`
   - `kubectl -n ambient-smoke logs -l gateway.networking.k8s.io/gateway-name=waypoint --tail=100`
   - `kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}'`
     (shows the Gateway API bundle version that GKE installed)
8. If check 4 failed: `kubectl -n ambient-smoke describe pod -l app=echo` (probe failures).

Before pasting, scan the output for anything that isn't in `envs/dev/terraform.tfvars`. The repo is public.

## Rollback and cost

- Run this only on a fresh `make up` cluster, then `make down`. The cluster is disposable. `make down`
  (about 9 min) is the real rollback: it removes Istio, its CRDs and every test object.
- `cleanup` exists for re-testing on the same cluster, e.g. after bumping `ISTIO_VERSION`. It deletes the
  `ambient-smoke` namespace and uninstalls the four releases. It **leaves** the `istio-system` namespace,
  its ResourceQuota, and any Istio CRDs that Helm doesn't remove.
- Cost: the time the cluster is up, on 1-2 Spot e2-standard-4 nodes (see IDP_NOTES section 4; a full
  up / test / down cycle is about an hour). No LoadBalancer is created: the waypoint is ClusterIP. Cloud NAT
  bills a small amount for image pulls.
- Per CLAUDE.md, agents must not run `cleanup` or `make down`. A human runs them.

## Decision table: if check 3 or check 4 fails (before ADR 0002)

| Symptom | Likely cause | Option | Cost / trade-off | Recommendation |
|---|---|---|---|---|
| **Check 3:** `client-other` reaches echo despite the policy, and check 1 shows the pods enrolled | Dataplane V2 eBPF/socketLB sends ClusterIP traffic around in-pod redirection (UNVERIFIED hypothesis) | **A. Rebuild without Dataplane V2.** In `modules/gke`: drop `datapath_provider = "ADVANCED_DATAPATH"`, enable Calico (`network_policy { enabled = true, provider = "CALICO" }` + `addons_config.network_policy_config`), update the CKV_GCP_12 skip comment | The cluster is recreated (it's ephemeral anyway). Loses DPv2 eBPF features and NetworkPolicy logging. Keeps ambient and the no-sidecar story in IDP_NOTES section 9 | **First choice** if ambient passes on a non-DPv2 test cluster. Confirm by re-running this smoke test on the rebuilt cluster |
| Same as above | Same | **B. Sidecar mode** (`istio-proxy` in each pod) on Dataplane V2 | About 50-100 MiB per pod (section 9). Breaks "developers own only their container". The ADR must explain why. Needs its own smoke test: sidecar mode has a known Cilium interaction with socketLB too (UNVERIFIED for GKE DPv2) | Choose if Dataplane V2 has to stay |
| Same as above | Same | **C. Other.** (1) Retry with a newer Istio patch/minor, or with any GKE/Istio-documented DPv2 setting (UNVERIFIED whether one exists). (2) Cloud Service Mesh (managed Istio): check its ambient + DPv2 support (UNVERIFIED). (3) Postpone the mesh and enforce only with NetworkPolicy | (1) is cheap and worth one try. (2) adds a vendor dependency. (3) loses SPIFFE identity, which IDP_NOTES #03 depends on | Try C(1) once, before A or B |
| **Check 4:** `client` blocked once the NetworkPolicy is applied | DPv2 does not match HBONE on 15008 as expected, or traffic reaches echo on 8080 (i.e. not via ztunnel; compare with check 3) | If check 3 passed: allow 15008 explicitly from the namespace or from the ztunnel source, re-test. If check 3 failed: see the check 3 rows | None if it's only a policy-shape fix | Fix the policy shape; it doesn't block ambient |
| **Check 4:** echo goes NotReady | DPv2 drops the probe traffic SNAT'd to 169.254.7.127 even though the ipBlock allows it | Try an ipBlock for the node CIDR as well, or check whether GKE needs another allow rule (UNVERIFIED) | Default-deny policies from the TeamNamespace operator (IDP_NOTES #01) will need the same exception | Must be fixed before the operator ships default-deny |
| **Check 4:** `client-other` allowed | The NetworkPolicy has no effect on mesh traffic (expected: it allows 15008 from anywhere), **and** ztunnel didn't deny | Same as check 3 | | Treat like a check 3 failure |

Record the outcome, the Istio version and the GKE version in ADR 0002 whichever way it goes.

## UNVERIFIED items

These were not checked against Istio or GKE docs; no docs are vendored in the repo. Confirm them for the
pinned version before treating a FAIL as a finding.

1. **Versions and images:**
   - `ISTIO_VERSION=1.27.1` may not support the Kubernetes minor of the REGULAR channel at run time. Pick
     a supported release and bump it deliberately.
   - Image tags `curlimages/curl:8.10.1` and `registry.k8s.io/e2e-test-images/agnhost:2.53` are believed
     to exist. Pin by digest once pulled.
2. **Chart values:**
   - `profile=ambient` on the `istiod` and `cni` charts.
   - `global.platform=gke` on istiod, cni and ztunnel. It's unknown whether ztunnel reads it, and whether
     DPv2 needs any extra istio-cni value.
3. **GKE ResourceQuota:** the `gcp-critical-pods` quota for `system-node-critical` in `istio-system`
   (shape taken from memory of Istio's GKE prerequisites).
4. **Resource names and labels:**
   - DaemonSet `istio-cni-node`; pod labels `app=ztunnel` and `k8s-app=istio-cni-node`.
   - Waypoint pod label `gateway.networking.k8s.io/gateway-name`, and how its ServiceAccount is named
     (the script looks it up rather than assuming).
   - Pod annotation `ambient.istio.io/redirection=enabled`.
5. **Ports and addresses:** HBONE port 15008 and probe SNAT address 169.254.7.127. Also whether Dataplane
   V2 enforces an `ipBlock` for a link-local address.
6. **istioctl:**
   - Subcommands `istioctl ztunnel-config workloads|services -i istio-system`, their output columns
     (`PROTOCOL` = `HBONE`), and `istioctl version --remote=false` output.
   - ztunnel log wording (`connection complete`, `src.identity="spiffe://..."`, deny messages).
7. **API versions:** `security.istio.io/v1` AuthorizationPolicy; `gateway.networking.k8s.io/v1` Gateway and
   HTTPRoute with a Service `parentRef` (GAMMA) on GKE-managed CRDs. Also whether GKE's Gateway API bundle
   is new enough for this Istio.
8. **Context name:** `--dns-endpoint` keeps the `gke_<project>_<zone>_idp` kube context name. If not, set
   `SMOKE_ALLOW_ANY_CONTEXT=1`.
9. **Root cause theory:** the socketLB explanation for a check 3 bypass, and the VIP-rewrite explanation for
   a check 5 failure, are hypotheses to test, not established facts.
10. **Default resource requests:** istiod's defaults (roughly 500m CPU / 2 GiB).
