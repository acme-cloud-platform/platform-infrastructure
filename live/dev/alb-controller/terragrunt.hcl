include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/alb-controller"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs = {
    cluster_name                  = "acme-cloud-dev-eks"
    cluster_endpoint               = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority  = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  environment = "dev"

  vpc_id                             = dependency.vpc.outputs.vpc_id
  eks_cluster_name                   = dependency.eks.outputs.cluster_name
  eks_cluster_endpoint                = dependency.eks.outputs.cluster_endpoint
  eks_cluster_certificate_authority   = dependency.eks.outputs.cluster_certificate_authority

  alb_controller_chart_version = "1.8.1"
}
