# argocd

Installs Argo CD with the `argo-cd` Helm chart (the one `helm_release` Terraform owns) and creates the **root Application** via the chart's `extraObjects`. The root app syncs `apps/` in `idp-gitops`; everything else (cert-manager, Istio, Tailscale, ...) is installed by Argo CD in sync-wave order.

- Dex and notifications are off; the server is ClusterIP-only (`server.insecure`, TLS comes later through Istio/Tailscale).
- The root Application has no resource finalizer, so `make down` cannot deadlock on it.
- Chart version is pinned (`chart_version`). The repo is public, so Argo CD needs no repository credentials.
- Open the UI with `kubectl -n argocd port-forward svc/argocd-server 8080:80`; the initial admin password is in secret `argocd-initial-admin-secret`.
