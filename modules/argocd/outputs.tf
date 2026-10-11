output "namespace" {
  description = "Namespace Argo CD runs in."
  value       = helm_release.argocd.namespace
}
