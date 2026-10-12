# cert-manager-dns

Google service account for cert-manager's Let's Encrypt DNS-01 challenges. It has `roles/dns.admin` on the one Cloud DNS zone and a Workload Identity binding for `cert-manager/cert-manager`, so no keys exist. In `idp-gitops`, annotate cert-manager's service account with `iam.gke.io/gcp-service-account: <output email>` and set `hostedZoneName` on the ClusterIssuer's Cloud DNS solver.
