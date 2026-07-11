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

variable "db_name" {
  type    = string
  default = "acmecloud"
}

variable "db_username" {
  type    = string
  default = "acmeadmin"
}

variable "db_instance_class" {
  description = "Free Tier eligible: db.t3.micro or db.t4g.micro"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage in GB — 20GB is within RDS Free Tier"
  type        = number
  default     = 20
}
