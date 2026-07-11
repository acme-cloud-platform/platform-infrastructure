terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }

  backend "s3" {
    bucket         = "acme-cloud-tfstate"
    key            = "alb-controller/terraform.tfstate"
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

# ---------- Auth data so the helm/kubernetes providers can talk to our cluster ----------
data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate  = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority)
  token                   = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
