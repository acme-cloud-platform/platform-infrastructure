include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/ecr"
}

inputs = {
  environment   = "qa"
  service_names = ["frontend", "backend", "notification"]
}
