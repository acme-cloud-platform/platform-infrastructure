output "eso_role_arn" {
  value = aws_iam_role.eso.arn
}

output "k8s_secret_name" {
  description = "The Kubernetes Secret backend-service should reference for DB credentials"
  value       = "rds-credentials"
}
