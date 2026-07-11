output "repository_urls" {
  description = "ECR repo URL per service — used in each service repo's GitHub Actions workflow"
  value       = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}
