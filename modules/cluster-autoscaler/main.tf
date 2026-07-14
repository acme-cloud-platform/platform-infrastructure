locals {
  name         = "${var.project_name}-${var.environment}"
  cluster_name = var.eks_cluster_name

  # Reuse the EKS OIDC provider created by the alb-controller module.
  eks_oidc_provider_arn = var.eks_oidc_provider_arn
  eks_oidc_issuer_path  = split("oidc-provider/", local.eks_oidc_provider_arn)[1]
}

# -------------------------------------------------------------------
# IAM Role assumed by the Cluster Autoscaler via IRSA
# -------------------------------------------------------------------

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${local.name}-cluster-autoscaler-role"

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
          "${local.eks_oidc_issuer_path}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${local.eks_oidc_issuer_path}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${local.name}-cluster-autoscaler-role"
  }
}

# -------------------------------------------------------------------
# IAM Policy
# Based on the official AWS Cluster Autoscaler permissions.
# -------------------------------------------------------------------

resource "aws_iam_policy" "cluster_autoscaler" {

  name        = "${local.name}-cluster-autoscaler-policy"
  description = "IAM policy for Kubernetes Cluster Autoscaler"

  policy = jsonencode({

    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ClusterAutoscalerRead"
        Effect = "Allow"

        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:DescribeWarmPool",
          "autoscaling:DescribeAutoScalingNotifications",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]

        Resource = "*"
      },
      {
        Sid    = "ClusterAutoscalerWrite"
        Effect = "Allow"

        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]

        Resource = "*"

        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled" = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# -------------------------------------------------------------------
# Kubernetes ServiceAccount
# -------------------------------------------------------------------

resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
    }

    labels = {
      "app.kubernetes.io/name"       = "cluster-autoscaler"
      "app.kubernetes.io/component"  = "cluster-autoscaler"
    }
  }
}

# -------------------------------------------------------------------
# Cluster Autoscaler
# -------------------------------------------------------------------

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"
  
  create_namespace = false
  atomic           = true
  wait             = true
  timeout          = 600

  set {
    name  = "autoDiscovery.clusterName"
    value = local.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "false"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = kubernetes_service_account.cluster_autoscaler.metadata[0].name
  }

  set {
    name  = "image.tag"
    value = var.cluster_autoscaler_image_tag
  }

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }

  set {
    name  = "extraArgs.scan-interval"
    value = "10s"
  }

  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }
  
  set {
    name  = "priorityClassName"
    value = "system-cluster-critical"
  }

  depends_on = [
    kubernetes_service_account.cluster_autoscaler,
    aws_iam_role_policy_attachment.cluster_autoscaler
  ]
}