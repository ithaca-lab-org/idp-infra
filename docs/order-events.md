# Order events and the notifier

`portal-api` publishes a JSON event per order change to Pub/Sub; the `notifier` pulls them and, only when `NOTIFIER_SEND_EMAIL=true`, sends email through Resend. Terraform: `modules/order-events`, applied by CI in `envs/persistent`.

```
portal-api ──publish──> order-events ──> order-events-notifier ──pull──> notifier ──> Resend (off by default)
                                              │ after 5 failed deliveries
                                              └──> order-events-dead-letter ──> order-events-dead-letter (inspect)
```

## Why the persistent stack

Nothing here depends on the cluster. Workload Identity bindings name the project pool (`<project>.svc.id.goog`) and a namespace/KSA, so they work for every rebuilt cluster (same as `cert-manager-dns`). Events published just before `make down` stay queued (7 days), idle cost is zero, and CI applies the change without a `make up`.

## Identities (no project roles)

| GSA | KSA | Grant |
|---|---|---|
| `portal-api@` | `idp-system/portal-api` | `roles/pubsub.publisher` on topic `order-events` |
| `notifier@` | `idp-system/notifier` | `roles/pubsub.subscriber` on subscription `order-events-notifier` |
| Pub/Sub service agent | - | `roles/pubsub.publisher` on `order-events-dead-letter`, `roles/pubsub.subscriber` on `order-events-notifier` (dead-lettering) |

No viewer role: the Go client (`cloud.google.com/go/pubsub/v2`) publishes and receives without `topics.get` / `subscriptions.get`. If a later client version calls `Exists()` or reads the config, add `roles/pubsub.viewer` on the subscription only.

## gitops wiring

- Annotate the KSAs with `iam.gke.io/gcp-service-account:` the `portal_api_sa` / `notifier_sa` outputs.
- portal-api: `PUBSUB_PROJECT=<project>`, `PUBSUB_TOPIC=order-events`.
- notifier: `PUBSUB_PROJECT=<project>`, `PUBSUB_SUBSCRIPTION=order-events-notifier`, `NOTIFIER_SEND_EMAIL` unset, and `RESEND_API_KEY` from Secret `idp-system/notifier-resend` key `api-key` with `optional: true` (the Secret only exists once the key has a version).
- NetworkPolicies must allow egress to `pubsub.googleapis.com:443` and the GKE metadata server (`169.254.169.254:80`, and `169.254.169.252:988` on Dataplane V2) for Workload Identity tokens.

## Resend API key

Terraform creates the secret `resend-api-key` with no version, so no value is ever in state. `make up` (`scripts/bootstrap-secrets.sh`) skips it while it has no version and copies it into `idp-system/notifier-resend` once it does. To add it:

```bash
P=project-324502ff-9928-4b17-a89
printf 'Resend API key: '; read -rs v; echo
printf '%s' "$v" | gcloud secrets versions add resend-api-key --data-file=- --project="$P"; unset v
```

Then re-run `./scripts/bootstrap-secrets.sh` (or the next `make up`) and restart the notifier.

## Dead letters

Inspect without acknowledging: `gcloud pubsub subscriptions pull order-events-dead-letter --limit=10 --project=<project>`. Add `--auto-ack` to drop them.

## Follow-ups

- **Resend domain verification:** DNS records for ithaca-idp.com in the persistent stack, required before NOTIFIER_SEND_EMAIL=true. Resend gives SPF (MX + TXT on a `send` subdomain), a DKIM TXT record and optionally DMARC; add them as `google_dns_record_set` resources next to `modules/dns`.
- External Secrets replaces the bootstrap copy in a later phase (ADR 0005); the notifier GSA would then get `roles/secretmanager.secretAccessor` on `resend-api-key` only.
