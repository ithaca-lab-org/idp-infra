# tenant-resources

Identity of the tenant resource broker (ADR 0010), in the persistent stack. See `docs/tenant-resources.md`.

- Google service account `idp-broker` with a Workload Identity binding for `idp-system/idp-broker` (`roles/iam.workloadIdentityUser`).
- One project-level binding for it: the custom role `projects/<project>/roles/idpBrokerBuckets` with the IAM condition `idp-buckets-and-menu-roles`:
  `resource.name.startsWith("projects/_/buckets/idp-") && api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/storage.objectViewer','roles/storage.objectUser'])`. The expression is built from `bucket_prefix` and `menu_roles`.
- Nothing else: no other roles, no project-level storage roles, no `storage.objects.*`. Container images need no new registry repository (`idp-broker` is an image name inside the existing repo `idp`).

## Order: bootstrap first

The custom role is created in `bootstrap/` (applied once by a human), not here, because the CI apply identity has `projectIamAdmin` and `serviceAccountAdmin` but deliberately not `roles/iam.roleAdmin`: CI can bind the role but cannot create or widen roles.

1. A human runs `terraform -chdir=bootstrap apply` (plan: 1 to add, the role).
2. Merge gate: `gcloud iam roles describe idpBrokerBuckets --project <project>` must succeed. Then merge the change that uses this module. The PR plan does NOT notice a missing role (`google_project_iam_member` does not check it at plan time); the apply on main does: the service account and Workload Identity binding are created, `google_project_iam_member.broker_buckets` fails, and every later persistent apply stays red until bootstrap is applied.

## Guardrails

The condition limits roles, not members or bucket settings. A human must set org policies before `RESOURCES_ENABLED`: see "Guardrails a human must set before RESOURCES_ENABLED" in `docs/tenant-resources.md`.

## Inputs

`project_id` (required); `account_id` (`idp-broker`), `broker_ksa` (`idp-system/idp-broker`), `role_id` (null: `projects/<project_id>/roles/idpBrokerBuckets`), `bucket_prefix` (`idp-`, must end with `-`), `menu_roles` (`roles/storage.objectViewer`, `roles/storage.objectUser`; each must start with `roles/storage.object`).

## Outputs

`service_account_email` (KSA annotation), `service_account_member`, `role_id`, `condition_expression`.
