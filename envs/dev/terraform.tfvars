project_id = "project-324502ff-9928-4b17-a89"
region     = "us-central1"
zone       = "us-central1-a"

# kubectl and CI reach the cluster through the IAM-gated DNS endpoint, so no IP
# allowlist is needed. Optionally allow a fixed IP on the public endpoint via
# TF_VAR_authorized_networks (do not commit your IP; this repo is public).
