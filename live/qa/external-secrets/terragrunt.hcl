include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/external-secrets"
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs = {
    cluster_name                  = "acme-cloud-qa-eks"
    cluster_endpoint               = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority  = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "rds" {
  config_path = "../rds"
  mock_outputs = {
    db_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "alb_controller" {
  config_path = "../alb-controller"
  mock_outputs = {
    eks_oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/mock"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  environment = "qa"

  eks_cluster_name                  = dependency.eks.outputs.cluster_name
  eks_cluster_endpoint               = dependency.eks.outputs.cluster_endpoint
  eks_cluster_certificate_authority  = dependency.eks.outputs.cluster_certificate_authority
  eks_oidc_provider_arn              = dependency.alb_controller.outputs.eks_oidc_provider_arn
  rds_secret_arn                     = dependency.rds.outputs.db_secret_arn

  eso_chart_version = "0.9.20"
  eso_namespace     = "external-secrets"
  app_namespace     = "default"
}
