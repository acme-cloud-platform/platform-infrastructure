variable "eks_cluster_name" {
  type = string
}

variable "eks_cluster_endpoint" {
  type = string
}

variable "eks_cluster_certificate_authority" {
  type = string
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana. Pass via a secret manager / TF_VAR / tfvars — never commit a real value."
  type        = string
  sensitive   = true
}

variable "prometheus_chart_version" {
  type    = string
  default = "25.24.1"
}

variable "grafana_chart_version" {
  type    = string
  default = "8.4.2"
}