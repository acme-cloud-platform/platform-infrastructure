terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state backend — bootstrap this S3 bucket + DynamoDB table manually
  # ONE TIME before running terraform init (see README-BACKEND-SETUP.md).
  # Keeping state in S3 (not local, not Git) is the enterprise-standard pattern.
  backend "s3" {
    bucket         = "acme-cloud-tfstate"       # must be globally unique — change if taken
    key            = "vpc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "acme-cloud-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
