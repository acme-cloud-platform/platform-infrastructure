locals {
  name = "${var.project_name}-${var.environment}"
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "acme-cloud-tfstate"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}

# ---------- Get GitHub's OIDC certificate thumbprint ----------
# AWS needs this to verify tokens actually came from GitHub, not an impersonator.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# ---------- The OIDC trust relationship itself, one-time per AWS account ----------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---------- The role GitHub Actions assumes — this replaces static AWS keys entirely ----------
resource "aws_iam_role" "github_deploy" {
  name = "${local.name}-github-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Pins trust to specific repos in our org — a workflow from any other
        # repo, even outside this org, cannot assume this role. ref:refs/heads/*
        # allows any branch; tighten to main only once we add environments.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for repo in var.github_repos :
            "repo:${var.github_org}/${repo}:*"
          ]
        }
      }
    }]
  })

  tags = {
    Name = "${local.name}-github-deploy-role"
  }
}

# ---------- Permissions: push/pull to ECR ----------
resource "aws_iam_role_policy" "ecr_push" {
  name = "${local.name}-ecr-push"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
    ]
  })
}

# ---------- Permissions: describe the EKS cluster (needed for update-kubeconfig) ----------
resource "aws_iam_role_policy" "eks_describe" {
  name = "${local.name}-eks-describe"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "*"
    }]
  })
}

# ---------- Grant this IAM role actual Kubernetes RBAC permissions inside the cluster ----------
# IAM alone doesn't let you kubectl apply — EKS access entries map an IAM
# principal to an in-cluster RBAC policy. Without this, GitHub Actions could
# authenticate to AWS fine but get "Unauthorized" from kubectl.
resource "aws_eks_access_entry" "github_deploy" {
  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  principal_arn = aws_iam_role.github_deploy.arn
}

resource "aws_eks_access_policy_association" "github_deploy" {
  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  principal_arn = aws_iam_role.github_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy" # can deploy/update workloads, cannot delete cluster-level resources

  access_scope {
    type = "cluster"
  }
}
