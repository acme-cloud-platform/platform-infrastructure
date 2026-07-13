include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/rds"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    private_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "destroy"]
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs = {
    cluster_security_group_id = "sg-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "destroy"]
}

inputs = {
  environment = "dev"

  vpc_id                         = dependency.vpc.outputs.vpc_id
  private_subnet_ids             = dependency.vpc.outputs.private_subnet_ids
  eks_cluster_security_group_id  = dependency.eks.outputs.cluster_security_group_id

  db_name              = "acmecloud"
  db_username          = "acmeadmin"
  db_instance_class    = "db.t3.micro"
  db_allocated_storage = 20
}
