# The one helm_release Terraform owns. Everything else is installed by Argo CD
# from idp-gitops, starting from the root Application created here.
locals {
  root_app = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = var.namespace
      # No resource finalizer on purpose: with one, `make down` deadlocks because
      # Argo CD is removed before it can process the finalizer.
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = var.gitops_path
        directory      = { recurse = false }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.namespace
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
      }
    }
  }

  # Small requests so Argo CD fits next to the platform add-ons on one e2-standard-4 Spot node.
  small = { requests = { cpu = "25m", memory = "128Mi" } }

  values = {
    # ClusterIP only; TLS and access come later through Istio / Tailscale.
    configs = { params = { "server.insecure" = true } }

    dex           = { enabled = false }
    notifications = { enabled = false }

    controller     = { resources = { requests = { cpu = "100m", memory = "256Mi" } } }
    server         = { resources = local.small }
    repoServer     = { resources = local.small }
    applicationSet = { resources = local.small }
    redis          = { resources = { requests = { cpu = "10m", memory = "32Mi" } } }

    extraObjects = [local.root_app]
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [yamlencode(local.values)]
}
