# Tenant resources spike (ADR 0010)

`scripts/spike-tenant-resources.sh` answers the three "Verify before building" points of ADR 0010 by observation. It does not assert pass/fail on the uncertain IAM-condition points; it prints `OBSERVED:` lines and a summary table.

## What it creates (all throwaway, removed on exit)

- Part A: buckets `idp-spike-a-<hex>` (bound) and `idp-spike-b-<hex>` (unbound); namespace `idp-spike-<hex>` with ServiceAccounts `spike-a`, `spike-b` (no annotations); a `roles/storage.objectUser` binding for the `spike-a` `principal://` on bucket A; four short pods (`curlimages/curl:8.11.1`).
- Part B: service account `idp-spike-broker-<hex>`; a project-level `roles/storage.admin` binding with a condition (`idp-spike-prefix`, later `idp-spike-prefix-rolelimit`); buckets `idp-spike-c-<hex>`, `spike-nomatch-<hex>` (only if the condition lets it through) and `idp-spike-test` (only if the name is free); `roles/iam.serviceAccountTokenCreator` for you on the service account, only if impersonation does not already work (the script says so).

Cleanup is by tracked name only: nothing is deleted by wildcard and no other bucket, service account, namespace or binding is touched. The state bucket is only read (`get-iam-policy`).

## Run

```
./scripts/spike-tenant-resources.sh                       # asks you to type yes
SPIKE_DRY_RUN=1 ./scripts/spike-tenant-resources.sh       # prints the plan, creates nothing
SPIKE_PART=A|B|all  SPIKE_YES=1  SPIKE_WAIT=300  SPIKE_COMMON_BUCKET=<name>
```

Needs gcloud (authenticated, project set), curl and, for part A, kubectl pointed at the idp cluster. Expect 10 to 20 minutes: conditional IAM bindings propagate slowly and each expectation is retried for up to `SPIKE_WAIT` seconds.

## Paste back

The `OBSERVED:` lines and the summary table. Never contains tokens.

## How to read it (ADR 0010 decisions)

| Line | Meaning |
|---|---|
| A1, A2 = 200 | The principal binding alone gives pod ADC access (point 2). Note the elapsed seconds: that is the IAM propagation delay the broker's `Ready` condition must tolerate. |
| A3, A4 = 403 | Other buckets and other ServiceAccounts are denied. Anything else is a design-breaking finding. |
| curl only | The Go and `gcloud storage` clients are not exercised; repeat by hand with them if the ADR needs it. |
| b1 allowed | A `resource.name` prefix condition works on bucket create. Denied: broker cannot be limited on create by name. |
| b2 denied | The prefix limit holds. Allowed: it does not, and the broker could create any bucket. |
| b3 denied | A non-matching bucket (the state bucket) is out of reach. Allowed: conditions do not guard reads. |
| b4 allowed | Conditioned bucket IAM writes work on matching buckets. |
| B-syn2 rejected | The role limit cannot be expressed: the menu is enforced only in broker code plus admission, and the Opus review must say so. |
| b5 allowed, b6 denied | The role limit is enforceable for bucket IAM. |
| b6 allowed ("role limit NOT enforced") | Same conclusion as a rejection: enforce the menu in code and admission. |
| B0 error text | The name-collision message; decide between failing clearly and a project-derived suffix. |

A "denied" right after a grant can be propagation, not policy; the script waits for the first allowed result before reading denials, but rerun if a result looks odd.

## Cost

Pennies: a few empty or one-object buckets for minutes and four small pods.

## Manual cleanup if the trap fails

The script prints the exact commands for anything it could not remove. Otherwise (replace `<hex>`):

```
gcloud storage rm --recursive gs://idp-spike-a-<hex> gs://idp-spike-b-<hex> gs://idp-spike-c-<hex>
gcloud storage rm --recursive gs://spike-nomatch-<hex>      # only if it exists
gcloud storage rm --recursive gs://idp-spike-test           # only if this run created it
kubectl delete namespace idp-spike-<hex>
gcloud projects get-iam-policy "$(gcloud config get-value project)" --format=json   # find the binding for idp-spike-broker-<hex>
gcloud iam service-accounts delete idp-spike-broker-<hex>@<project>.iam.gserviceaccount.com
```

Deleting the service account leaves the conditional project binding as a dead `deleted:serviceAccount:...` member; remove it in the Console (IAM) or with `gcloud projects remove-iam-policy-binding ... --condition-from-file=<file>`. Find leftovers with `gcloud storage buckets list --filter='labels.idp-spike=true'`.
