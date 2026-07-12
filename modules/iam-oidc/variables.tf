variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "acme-cloud"
}

variable "environment" {
  type    = string
  default = "poc"
}

variable "github_org" {
  description = "Your GitHub org — only workflows from repos in this org can assume the deploy role"
  type        = string
  default     = "acme-cloud-platform"
}

variable "github_repos" {
  description = "Exact repos allowed to assume the deploy role via OIDC. Wildcard branch (*) allowed, but repo names are pinned — no other repo, even in the same org, can use this role."
  type        = list(string)
  default = [
    "frontend-service",
    "backend-service",
    "notification-service",
    "platform-infrastructure",
  ]
}

# ---------- Injected by Terragrunt's `dependency "eks"` block ----------
variable "eks_cluster_name" {
  type = string
}
