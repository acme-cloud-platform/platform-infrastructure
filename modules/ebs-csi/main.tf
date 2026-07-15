locals {
  name         = "${var.project_name}-${var.environment}"
  cluster_name = var.eks_cluster_name

  # Reuse the EKS OIDC provider created by the alb-controller module — same
  # pattern as cluster-autoscaler and external-secrets. One OIDC provider
  # per cluster, referenced everywhere IRSA is needed.
  eks_oidc_provider_arn = var.eks_oidc_provider_arn
  eks_oidc_issuer_path  = split("oidc-provider/", local.eks_oidc_provider_arn)[1]
}

# -------------------------------------------------------------------
# IAM Role assumed by the EBS CSI controller pods via IRSA
# -------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name = "${local.name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Federated = local.eks_oidc_provider_arn
      }

      Action = "sts:AssumeRoleWithWebIdentity"

      Condition = {
        StringEquals = {
          "${local.eks_oidc_issuer_path}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.eks_oidc_issuer_path}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${local.name}-ebs-csi-role"
  }
}

# AWS-managed policy with exactly what the CSI controller needs
# (CreateVolume, AttachVolume, DeleteSnapshot, etc.)
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -------------------------------------------------------------------
# The EBS CSI Driver — installed as a first-party EKS addon (not Helm).
# AWS ships and patches this addon directly; using aws_eks_addon means we
# get automatic compatibility with the cluster's K8s version and don't have
# to track chart versions ourselves.
# -------------------------------------------------------------------

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = local.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

# -------------------------------------------------------------------
# gp3 StorageClass using the CSI provisioner. The cluster's pre-existing
# "gp2" StorageClass uses the deprecated in-tree provisioner
# (kubernetes.io/aws-ebs), which no longer works on this K8s version — PVCs
# referencing it hang in Pending forever. This is the one PVCs should
# actually use, and it's marked default so any PVC that doesn't specify a
# storageClassName picks it up automatically (gp3 is also cheaper and
# faster than gp2 at the same size).
# -------------------------------------------------------------------

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "gp3"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
