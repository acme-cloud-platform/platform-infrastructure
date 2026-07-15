include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/ebs-csi"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                  = "acme-cloud-poc-eks"
    cluster_endpoint               = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority  = "bW9jaw=="
  }

  mock_outputs_allowed_terraform_commands = [
    "plan",
    "validate",
    "destroy"
  ]
}

dependency "alb_controller" {
  config_path = "../alb-controller"

  mock_outputs = {
    eks_oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/mock"
  }

  mock_outputs_allowed_terraform_commands = [
    "plan",
    "validate",
    "destroy"
  ]
}

inputs = {
  environment = "poc"

  eks_cluster_name                  = dependency.eks.outputs.cluster_name
  eks_cluster_endpoint               = dependency.eks.outputs.cluster_endpoint
  eks_cluster_certificate_authority  = dependency.eks.outputs.cluster_certificate_authority

  eks_oidc_provider_arn = dependency.alb_controller.outputs.eks_oidc_provider_arn
}
