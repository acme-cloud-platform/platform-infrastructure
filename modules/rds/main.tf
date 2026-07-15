locals {
  name               = "${var.project_name}-${var.environment}"
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  eks_node_sg_id     = var.eks_cluster_security_group_id
}

# ---------- Generate a strong random password (never typed/committed anywhere) ----------
resource "random_password" "db" {
  length  = 24
  special = false # avoids characters that sometimes break connection strings/URL-encoding
}

# ---------- Store credentials in Secrets Manager, not in Terraform state readably, not in Git ----------
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.name}-rds-credentials"
  recovery_window_in_days = 0 # POC only: allows immediate delete+recreate on teardown/rebuild without manual force-delete
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    host     = aws_db_instance.main.address
    port     = 5432
  })
}

# ---------- DB subnet group — private subnets only ----------
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = local.private_subnet_ids

  tags = {
    Name = "${local.name}-db-subnet-group"
  }
}

# ---------- Security group — inbound allowed ONLY from EKS nodes, port 5432 ----------
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Allow Postgres access only from EKS worker nodes"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-rds-sg"
  }
}

# ---------- RDS instance — private subnet, no public IP ----------
resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = "16.4"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # locked down — no public IP, no internet access

  # POC-appropriate settings — would harden these for real prod (see note below)
  multi_az                = false
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name = "${local.name}-db"
  }
}

# NOTE on POC vs production tradeoffs, worth mentioning if asked:
# - multi_az = false: single AZ is fine for a POC; real prod would run Multi-AZ
#   for automatic failover.
# - skip_final_snapshot = true / deletion_protection = false: makes `terraform
#   destroy` clean and fast for our teardown-every-session workflow. Real prod
#   would flip both so an accidental destroy can't silently delete data.
