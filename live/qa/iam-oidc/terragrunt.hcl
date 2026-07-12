include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/iam-oidc"
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs = {
    cluster_name = "acme-cloud-qa-eks"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  environment = "qa"

  eks_cluster_name = dependency.eks.outputs.cluster_name

  # Which GitHub repos are trusted to assume the deploy role — this is the
  # one place you'd add a new repo name if a real 4th microservice showed up.
  github_org = "acme-cloud-platform"
  github_repos = [
    "frontend-service",
    "backend-service",
    "notification-service",
    "platform-infrastructure",
  ]
}
