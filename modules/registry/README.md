# registry

Docker Artifact Registry repository with cleanup policies: keep the 10 newest versions, delete untagged after 7 days, delete everything else after 30 days (KEEP wins over DELETE). Lives in the persistent stack.
