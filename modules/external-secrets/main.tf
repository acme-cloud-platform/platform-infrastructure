locals {
  name         = "${var.project_name}-${var.environment}"
  cluster_name = var.eks_cluster_name

  # Reuse the SAME EKS OIDC provider created in Phase 6 — an AWS account can
  # only have ONE OIDC provider per issuer URL, so we read it from remote
  # state instead of creating a second one (which would fail with a
  # "provider already exists" error).
  eks_oidc_provider_arn = var.eks_oidc_provider_arn
  eks_oidc_issuer_path  = split("oidc-provider/", local.eks_oidc_provider_arn)[1]
}

resource "kubernetes_namespace" "eso" {
  metadata {
    name = var.eso_namespace
  }
}

# ---------- IAM role the ESO pod assumes via IRSA, trusted only by its own ServiceAccount ----------
resource "aws_iam_role" "eso" {
  name = "${local.name}-external-secrets-role"

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
          "${local.eks_oidc_issuer_path}:sub" = "system:serviceaccount:${var.eso_namespace}:external-secrets"
          "${local.eks_oidc_issuer_path}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${local.name}-external-secrets-role"
  }
}

# ---------- Scoped narrowly: read-only on exactly the one RDS credentials secret ----------
resource "aws_iam_role_policy" "eso_secrets_read" {
  name = "${local.name}-eso-secrets-read"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = var.rds_secret_arn
    }]
  })
}

resource "kubernetes_service_account" "eso" {
  metadata {
    name      = "external-secrets"
    namespace = var.eso_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.eso.arn
    }
  }
  depends_on = [kubernetes_namespace.eso]
}

# ---------- The operator itself ----------
resource "helm_release" "eso" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.eso_chart_version
  namespace  = var.eso_namespace

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.eso.metadata[0].name
  }

  depends_on = [kubernetes_service_account.eso]
}

# ---------- Tells ESO where to read secrets from — points at Secrets Manager in our account/region ----------
# Using ClusterSecretStore (not namespaced SecretStore) because our
# ServiceAccount lives in the eso_namespace ("external-secrets"), not in the
# app namespace where secrets get consumed — SecretStore's admission webhook
# rejects a serviceAccountRef pointing at a different namespace, but
# ClusterSecretStore is designed to reference one from anywhere.
resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secretsmanager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = kubernetes_service_account.eso.metadata[0].name
                namespace = var.eso_namespace
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.eso]
}

# ---------- The actual sync job: pulls the RDS secret, materializes it as a normal K8s Secret ----------
# backend-service (Phase 8) will mount this Secret directly — never sees
# Secrets Manager or AWS APIs itself.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rds-credentials"
      namespace = var.app_namespace
    }
    spec = {
      refreshInterval = "1h" # re-syncs periodically, picks up rotated passwords automatically
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "rds-credentials" # this is the K8s Secret name backend-service will reference
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.rds_secret_arn
        }
      }]
    }
  }

  depends_on = [kubernetes_manifest.cluster_secret_store]
}
