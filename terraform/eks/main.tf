locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.vpc.outputs.public_subnet_ids
}

# ---------- EKS control plane ----------
resource "aws_eks_cluster" "main" {
  name     = "${local.name}-eks"
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    # Control plane ENIs go in private subnets. Public subnets are included too
    # so the API server endpoint can optionally be made publicly reachable —
    # useful for kubectl access from your laptop during POC/dev.
    subnet_ids              = concat(local.private_subnet_ids, local.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true # fine for POC; would restrict via CIDR allowlist in real prod
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = {
    Name = "${local.name}-eks"
  }
}

# ---------- Managed node group (the actual EC2 worker nodes) ----------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.node.arn

  # Worker nodes always live in private subnets — no public IPs, no direct
  # internet exposure. Outbound internet (image pulls, updates) goes through
  # the NAT Gateway we built in Phase 2.
  subnet_ids = local.private_subnet_ids

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
  ]

  tags = {
    Name = "${local.name}-nodes"
  }
}
