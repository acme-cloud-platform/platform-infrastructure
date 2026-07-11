output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "eks_oidc_provider_arn" {
  description = "The cluster's own OIDC provider — different from the GitHub OIDC provider in Phase 5"
  value       = aws_iam_openid_connect_provider.eks.arn
}
