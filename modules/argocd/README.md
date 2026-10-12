# argocd

Installs Argo CD with the `argo-cd` Helm chart, then creates the **root Application** with the `argocd-apps` chart in a second release that depends on the first. (Two releases are required: Helm validates every object against the API before installing, so an Application cannot be in the same release that installs its CRD.) These are the only Helm releases Terraform owns. The root app syncs `apps/` in `idp-gitops`; everything else (cert-manager, Istio, Tailscale, ...) is installed by Argo CD in sync-wave order.

- Dex and notifications are off; the server is ClusterIP-only (`server.insecure`, TLS comes later through Istio/Tailscale).
- The root Application has no resource finalizer, so `make down` cannot deadlock on it.
- Chart version is pinned (`chart_version`). The repo is public, so Argo CD needs no repository credentials.
- Open the UI with `kubectl -n argocd port-forward svc/argocd-server 8080:80`; the initial admin password is in secret `argocd-initial-admin-secret`.
