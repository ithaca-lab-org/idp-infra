# ingress

Reserved regional external IP for the Istio ingress gateway and a wildcard A record `*.apps.<domain>` pointing at it. Lives in the persistent stack so the address and DNS survive `make down`. The gateway in `idp-gitops` requests this IP by value (see its `platform/` values).
