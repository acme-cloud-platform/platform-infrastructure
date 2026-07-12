locals {
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  public_subnet_ids  = var.public_subnet_ids
}

# ---------- Latest AWS-recommended EKS-optimized AL2023 AMI for our cluster version ----------
# Fetched dynamically instead of hardcoded, so it always matches cluster_version
# and picks up AWS security patches automatically on the next apply.
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# ---------- Custom launch template: only reason we need this is to raise max-pods ----------
# AL2023 EKS AMIs bootstrap via "nodeadm" (a YAML NodeConfig), not the old
# bootstrap.sh script. This overrides the kubelet's --max-pods, which
# otherwise defaults to a low, static, ENI-based number regardless of
# whether VPC CNI prefix delegation is enabled — that's the gap that caused
# our Phase 7 "Too many pods" scheduling failures on t3.micro nodes.
resource "aws_launch_template" "nodes" {
  name_prefix = "${local.name}-nodes-"
  image_id    = nonsensitive(data.aws_ssm_parameter.eks_ami.value)

  user_data = base64encode(<<-EOT
    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${local.name}-eks
        apiServerEndpoint: ${aws_eks_cluster.main.endpoint}
        certificateAuthority: ${aws_eks_cluster.main.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr}
      kubelet:
        flags:
          - "--max-pods=110"
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name}-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
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

  # API_AND_CONFIG_MAP enables EKS Access Entries (IAM-role-to-RBAC mapping,
  # used in Phase 5 for GitHub Actions OIDC deploy access) while keeping the
  # legacy aws-auth configmap method working too, in case anything still needs it.
  # bootstrap_cluster_creator_admin_permissions must be explicitly set to true
  # (matching AWS's original default) — leaving it unset causes Terraform to
  # see a diff and force a full cluster replacement, which we don't want here.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
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

  # Custom launch template (above) — only used to raise max-pods via nodeadm
  # config. Instance type is still controlled here, not in the template.
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

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

# ---------- VPC CNI addon config: enable prefix delegation ----------
# Small instance types (t3.micro etc) can only host a handful of pods by
# default, because pod IPs are allocated one-per-ENI-slot. Prefix delegation
# lets the CNI hand out /28 IP prefixes instead, massively raising the
# pods-per-node ceiling on the SAME instance type — no extra EC2 cost.
# This is what fixed our "0/2 nodes available: Too many pods" scheduling
# failure in Phase 7 without needing to add a 3rd node.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
