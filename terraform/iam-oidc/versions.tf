terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "acme-cloud-tfstate"
    key            = "iam-oidc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "acme-cloud-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
