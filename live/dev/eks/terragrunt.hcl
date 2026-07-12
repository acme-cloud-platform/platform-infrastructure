include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/eks"
}

# This replaces the old `data "terraform_remote_state" "vpc"` block that
# used to live inside modules/eks/versions.tf. Terragrunt reads vpc's
# outputs directly and passes them in as normal input variables — the
# module itself no longer needs to know HOW to fetch them, just that
# they'll be there.
dependency "vpc" {
  config_path = "../vpc"

  # Lets `terragrunt plan` work even before vpc has been applied yet, by
  # substituting placeholder values — genuinely useful the very first time
  # you stand up a brand new environment from scratch.
  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    private_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001"]
    public_subnet_ids  = ["subnet-00000000000000002", "subnet-00000000000000003"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  environment = "dev"

  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids
  public_subnet_ids  = dependency.vpc.outputs.public_subnet_ids

  cluster_version     = "1.30"
  node_instance_type  = "t3.micro" # Free Tier restriction — see Must-Manual-setup.md
  node_desired_size   = 2
  node_min_size       = 1
  node_max_size       = 3
}
