terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "acme-cloud-tfstate"
    key            = "eks/terraform.tfstate"   # different key = separate state file from vpc/
    region         = "us-east-1"
    dynamodb_table = "acme-cloud-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# Pull VPC outputs from the vpc/ module's state file, instead of hardcoding IDs.
# This is how separate Terraform states reference each other cleanly.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "acme-cloud-tfstate"
    key    = "vpc/terraform.tfstate"
    region = "us-east-1"
  }
}
