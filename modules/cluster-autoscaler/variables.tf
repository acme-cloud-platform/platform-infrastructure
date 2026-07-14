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

variable "cluster_autoscaler_chart_version" {
  type    = string
  default = "9.46.6"
}

variable "cluster_autoscaler_image_tag" {
  type    = string
  default = "v1.30.2"
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

variable "eks_oidc_provider_arn" {
  type = string
}