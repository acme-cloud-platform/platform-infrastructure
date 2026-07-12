output "db_endpoint" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  description = "Secrets Manager ARN — External Secrets Operator (Phase 7) will sync this into a K8s Secret"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
