output "github_deploy_role_arn" {
  description = "Put this ARN in each service repo's workflow — this is what replaces stored AWS access keys"
  value       = aws_iam_role.github_deploy.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
