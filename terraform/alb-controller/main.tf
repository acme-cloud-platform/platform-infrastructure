locals {
  name         = "${var.project_name}-${var.environment}"
  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
}

# ---------- The EKS cluster's own OIDC issuer (different from GitHub's OIDC in Phase 5) ----------
# This is what lets a POD running inside the cluster assume an IAM role —
# known as IRSA (IAM Roles for Service Accounts). Every EKS cluster has one
# of these issuer URLs automatically; we just need to register it with IAM.
data "tls_certificate" "eks_oidc" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

# ---------- IAM role the controller pod will assume, trusted only by the
#            specific Kubernetes ServiceAccount it runs as ----------
resource "aws_iam_role" "alb_controller" {
  name = "${local.name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${local.name}-alb-controller-role"
  }
}

# ---------- Official AWS-published policy — everything the controller needs
#            to create/manage ALBs, target groups, listeners, security groups ----------
resource "aws_iam_policy" "alb_controller" {
  name   = "${local.name}-alb-controller-policy"
  policy = file("${path.module}/iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---------- The ServiceAccount the controller pod runs as, annotated to
#            trigger IRSA (pod automatically gets temporary AWS creds) ----------
resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

# ---------- The controller itself ----------
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = local.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false" # we created it above ourselves, with the IRSA annotation
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = data.terraform_remote_state.vpc.outputs.vpc_id
  }

  depends_on = [
    kubernetes_service_account.alb_controller,
    aws_iam_role_policy_attachment.alb_controller,
  ]
}
