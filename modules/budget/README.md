# budget

Monthly billing budget scoped to the project, alerting at 50/90/100% of actual spend and 100% forecast. Alerts go to billing admins (default IAM recipients). Needs `billing.costsManager` on the billing account (granted to the apply SA by `bootstrap/`).

The manual budget from Step 1 duplicates this one: delete it in the console after the first apply.
