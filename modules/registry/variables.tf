variable "location" {
  description = "Region of the repository."
  type        = string
}

variable "repository_id" {
  description = "Repository name."
  type        = string
  default     = "idp"
}
