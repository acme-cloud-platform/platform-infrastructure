# This file is intentionally tiny. All the actual resource logic lives in
# modules/vpc/ — this file just says "use that module, here" and supplies
# this environment's specific values.
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  environment = "qa"

  vpc_cidr             = "10.2.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.2.0.0/24", "10.2.1.0/24"]
  private_subnet_cidrs = ["10.2.10.0/24", "10.2.11.0/24"]
}
