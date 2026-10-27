# order-events

Pub/Sub pipeline for portal order events, in the persistent stack. See `docs/order-events.md`.

- Topic `order-events`, dead-letter topic `order-events-dead-letter` (with an inspection subscription of the same name).
- Pull subscription `order-events-notifier`: ack deadline 60 s, retry backoff 10-300 s, dead-letter after 5 delivery attempts, 7-day retention, never expires.
- The Pub/Sub service agent gets `roles/pubsub.publisher` on the dead-letter topic and `roles/pubsub.subscriber` on `order-events-notifier` only (what dead-lettering needs).
- Google service accounts with no project roles: `portal-api` (`roles/pubsub.publisher` on `order-events`) and `notifier` (`roles/pubsub.subscriber` on `order-events-notifier`), each with a Workload Identity binding for `idp-system/portal-api` and `idp-system/notifier`.
- Secret Manager secret `resend-api-key` without a version (no value in state). `scripts/bootstrap-secrets.sh` copies it to `idp-system/notifier-resend` once a human adds a version.

In `idp-gitops`, annotate each KSA with `iam.gke.io/gcp-service-account: <output email>` and set `PUBSUB_PROJECT`, `PUBSUB_TOPIC` / `PUBSUB_SUBSCRIPTION` from the outputs.
