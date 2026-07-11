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

variable "service_names" {
  description = "One ECR repo per microservice"
  type        = list(string)
  default     = ["frontend", "backend", "notification"]
}
