# -------------------------------------------------------------------
# IAM Role ARN
# Useful if future platform components need to reference the
# Cluster Autoscaler's IRSA role.
# -------------------------------------------------------------------

output "cluster_autoscaler_role_arn" {
  description = "IAM role assumed by the Cluster Autoscaler via IRSA"
  value       = aws_iam_role.cluster_autoscaler.arn
}

# -------------------------------------------------------------------
# Helm Release Name
# Useful for debugging and future Terragrunt dependencies.
# -------------------------------------------------------------------

output "cluster_autoscaler_release_name" {
  description = "Helm release name"
  value       = helm_release.cluster_autoscaler.name
}