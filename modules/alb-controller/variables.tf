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

variable "alb_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller"
  type        = string
  default     = "1.8.1"
}

# ---------- Injected by Terragrunt dependency blocks (vpc + eks) ----------
variable "vpc_id" {
  type = string
}

variable "eks_cluster_name" {
  type = string
}

variable "eks_cluster_endpoint" {
  type = string
}

variable "eks_cluster_certificate_authority" {
  type = string
}
