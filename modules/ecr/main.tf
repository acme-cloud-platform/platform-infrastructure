locals {
  name = "${var.project_name}-${var.environment}"
}

resource "aws_ecr_repository" "service" {
  for_each = toset(var.service_names)

  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE" # once a tag (e.g. a commit SHA) is pushed, it can't be overwritten — prevents silent "latest got swapped" bugs

  image_scanning_configuration {
    scan_on_push = true # auto-scans every pushed image for known CVEs
  }

  tags = {
    Name    = "${local.name}-${each.key}"
    Service = each.key
  }
}

# Keep only the last 10 images per repo — otherwise ECR storage (and cost)
# grows unbounded as CI/CD pushes a new image on every commit.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}
