# Just provider requirements — no backend block. Terragrunt generates the
# backend automatically (see live/terragrunt.hcl) since it needs to be
# different per environment (different state key), while this module's
# actual resource logic stays identical across every environment.
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
