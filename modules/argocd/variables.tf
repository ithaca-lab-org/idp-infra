variable "chart_version" {
  description = "argo-cd Helm chart version. Pinned on purpose; bump deliberately (Argo CD v3.5.4 for chart 10.10.2)."
  type        = string
  default     = "10.10.2"
}

variable "apps_chart_version" {
  description = "argocd-apps Helm chart version (creates the root Application). Pinned on purpose."
  type        = string
  default     = "2.0.6"
}

variable "namespace" {
  description = "Namespace for Argo CD and the root Application."
  type        = string
  default     = "argocd"
}

variable "gitops_repo_url" {
  description = "Git repository the root Application syncs from."
  type        = string
}

variable "gitops_revision" {
  description = "Branch or tag of the GitOps repository to track."
  type        = string
  default     = "main"
}

variable "gitops_path" {
  description = "Directory in the GitOps repository that holds the child Applications."
  type        = string
  default     = "apps"
}
