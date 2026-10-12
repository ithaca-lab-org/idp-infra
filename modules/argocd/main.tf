# Terraform installs Argo CD and the root Application, and nothing else. Every
# other add-on is installed by Argo CD from idp-gitops.
locals {
  # Map shape expected by the argocd-apps chart.
  root_app = {
    root = {
      namespace = var.namespace
      project   = "default"
      # No resource finalizer on purpose: with one, `make down` deadlocks because
      # Argo CD is removed before it can process the finalizer.
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

# The root Application is a separate release because Helm validates every object
# in a release against the API *before* installing it, so an Application cannot
# live in the same release that installs the Application CRD (extraObjects fails
# with "no matches for kind Application").
resource "helm_release" "root_app" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.apps_chart_version
  namespace  = var.namespace

  wait    = true
  timeout = 300

  values = [yamlencode({ applications = local.root_app })]

  depends_on = [helm_release.argocd]
}
