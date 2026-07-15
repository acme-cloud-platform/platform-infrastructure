output "ebs_csi_role_arn" {
  description = "IAM role assumed by the EBS CSI controller via IRSA"
  value       = aws_iam_role.ebs_csi.arn
}

output "gp3_storage_class_name" {
  description = "Name of the default gp3 StorageClass, for reference by other modules (e.g. monitoring)"
  value       = kubernetes_storage_class.gp3.metadata[0].name
}
