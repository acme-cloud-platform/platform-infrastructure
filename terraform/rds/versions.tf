terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "acme-cloud-tfstate"
    key            = "rds/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "acme-cloud-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "acme-cloud-tfstate"
    key    = "vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "acme-cloud-tfstate"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}
