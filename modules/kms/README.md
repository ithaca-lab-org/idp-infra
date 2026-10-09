# kms

Key ring `idp` with the `gke-secrets` key (90-day rotation) for GKE application-layer secrets encryption, plus the grant that lets the GKE service agent use it. Key rings cannot be deleted in GCP, so this belongs in the persistent stack.
