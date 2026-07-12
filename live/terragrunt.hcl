# Root Terragrunt config. Every module's terragrunt.hcl does
# `include "root" { path = find_in_parent_folders() }` to inherit
# everything defined here — this is what makes the setup DRY: the S3
# backend config and AWS provider block are written ONCE, here, instead of
# copy-pasted into every module like our original terraform/*/versions.tf
# files did.

locals {
  aws_region   = "us-east-1"
  project_name = "acme-cloud"

  # tfstate bucket/lock table — same ones bootstrapped manually back in
  # Phase 2 (see Must-Manual-setup.md). One bucket serves every environment;
  # environments never collide because each gets its own state KEY below.
  tfstate_bucket = "acme-cloud-tfstate"
  tfstate_lock_table = "acme-cloud-tf-locks"
}

# Generates a backend "s3" {} block for every module automatically — the
# state key is derived from each module's folder path, so
# live/poc/vpc/ → key "poc/vpc/terraform.tfstate", and
# live/staging/vpc/ → key "staging/vpc/terraform.tfstate" if that ever gets
# added. No manual key-per-module bookkeeping like the old versions.tf files
# required.
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket         = local.tfstate_bucket
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    dynamodb_table = local.tfstate_lock_table
    encrypt        = true
  }
}

# Generates the AWS provider block for every module automatically.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
}
EOF
}

# Values every environment inherits by default. Each live/<env>/<module>/
# terragrunt.hcl can override any of these in its own `inputs` block.
inputs = {
  aws_region   = local.aws_region
  project_name = local.project_name
}
