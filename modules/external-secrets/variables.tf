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

variable "eso_chart_version" {
  description = "Helm chart version for external-secrets"
  type        = string
  default     = "0.9.20"
}

variable "eso_namespace" {
  type    = string
  default = "external-secrets"
}

variable "app_namespace" {
  description = "Namespace where backend-service will run and where the synced DB Secret should land"
  type        = string
  default     = "default"
}

# ---------- Injected by Terragrunt dependency blocks (eks, rds, alb-controller) ----------
variable "eks_cluster_name" {
  type = string
}

variable "eks_cluster_endpoint" {
  type = string
}

variable "eks_cluster_certificate_authority" {
  type = string
}

variable "eks_oidc_provider_arn" {
  description = "Reused from the alb-controller module's output — same OIDC provider, one per account"
  type        = string
}

variable "rds_secret_arn" {
  type = string
}
