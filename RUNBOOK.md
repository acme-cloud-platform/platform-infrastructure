# RUNBOOK — how to run this project

This is our command reference. Every command we've actually run, grouped by
phase, so we (or anyone else) can rebuild or verify the whole thing from
scratch without re-figuring things out.

---

## One-time setup (do this only once, ever)

See `Must-Manual-setup.md` for:
- Creating the AWS account + IAM user
- Installing AWS CLI + Terraform
- `aws configure` setup
- Creating the S3 bucket + DynamoDB table for Terraform remote state

---

## Phase 2 — VPC / Networking

### Deploy
```bash
cd platform-infrastructure/terraform/vpc
terraform init
terraform plan
terraform apply
```

### Verify
```bash
# Confirm VPC exists
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=acme-cloud-poc-vpc"

# Confirm subnets
aws ec2 describe-subnets --filters "Name=tag:Name,Values=acme-cloud-poc-*"
```
Or just check AWS Console → VPC → Your VPCs → Resource map tab (shows subnets, route tables, IGW, NAT visually).

### Destroy (end of session, to stop billing)
```bash
cd platform-infrastructure/terraform/vpc
terraform destroy
```

---

## Phase 3 — EKS cluster + node group

### Deploy
```bash
cd platform-infrastructure/terraform/eks
terraform init
terraform plan
terraform apply
```
⏱ Cluster creation: ~10 min. Node group creation: ~5-15 min (longer if instance type gets rejected — see troubleshooting below).

### Connect kubectl to the cluster
```bash
aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
```

### Verify — this is the real proof it's working
```bash
# Nodes should show STATUS = Ready
kubectl get nodes

# System pods should all show STATUS = Running
kubectl get pods -A
```

### Verify via AWS CLI (alternative to kubectl)
```bash
# Cluster status
aws eks describe-cluster --name acme-cloud-poc-eks --query 'cluster.status'

# Node group status
aws eks describe-nodegroup \
  --cluster-name acme-cloud-poc-eks \
  --nodegroup-name acme-cloud-poc-nodes \
  --query 'nodegroup.status'

# Underlying EC2 instances in the node group's Auto Scaling Group
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'acme-cloud-poc-nodes')].Instances"
```

### Check via AWS Console
- EKS → Clusters → `acme-cloud-poc-eks` → **Compute** tab → node group health
- EC2 → Auto Scaling Groups → find the `eks-acme-cloud-poc-nodes-...` group → **Activity** tab for launch history/errors

### Destroy (end of session, to stop billing)
```bash
cd platform-infrastructure/terraform/eks
terraform destroy
```
Then destroy the VPC too (eks depends on vpc, so eks must go first):
```bash
cd ../vpc
terraform destroy
```

---

## Phase 4 — ECR repos + RDS

### Deploy ECR (no dependencies — can run any time)
```bash
cd platform-infrastructure/terraform/ecr
terraform init
terraform plan
terraform apply
```

### Deploy RDS (depends on vpc + eks — both must be up first)
```bash
cd ../rds
terraform init
terraform plan
terraform apply
```

### Verify ECR
```bash
aws ecr describe-repositories --query 'repositories[].repositoryName'
```

### Verify RDS
```bash
aws rds describe-db-instances \
  --db-instance-identifier acme-cloud-poc-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,PubliclyAccessible:PubliclyAccessible,Endpoint:Endpoint.Address}'

# Confirm the credentials secret exists (does not print the password)
aws secretsmanager describe-secret --secret-id acme-cloud-poc-rds-credentials
```

### Destroy (end of session)
```bash
cd terraform/rds && terraform destroy   # rds first (depends on eks/vpc)
cd ../ecr && terraform destroy           # ecr independent, any order is fine
```

---

## Troubleshooting we've hit so far

### "InvalidParameterCombination - not eligible for Free Tier"
New AWS accounts get a temporary restriction blocking non-Free-Tier EC2 instance types. Check what's allowed:
```bash
aws ec2 describe-instance-types \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'InstanceTypes[].InstanceType'
```
Fix: set `node_instance_type` in `terraform/eks/variables.tf` to a Free Tier type (`t3.micro` / `t2.micro`), then `terraform apply` again — Terraform auto-detects the failed (tainted) node group and recreates it. Same fix pattern applies to `db_instance_class` in `terraform/rds/variables.tf` if RDS hits the same restriction.

### Node group stuck in "CREATING" for a long time
Normal — first-time node group creation is the slowest step (15-25 min). Check real status instead of guessing:
```bash
aws eks describe-nodegroup --cluster-name acme-cloud-poc-eks --nodegroup-name acme-cloud-poc-nodes --query 'nodegroup.status'
```
Only worry if this returns `CREATE_FAILED` — check the node group's **Health** section in the AWS Console for the actual error message.

### `terraform apply` warning: "dynamodb_table is deprecated"
Harmless for now, still works. Future cleanup: migrate to `use_lockfile` parameter. Not urgent.

---

## Phase 5 — IAM OIDC provider for GitHub Actions

### Deploy (depends on eks — access entries need the cluster to exist)
```bash
cd platform-infrastructure/terraform/iam-oidc
terraform init
terraform plan
terraform apply
```

### Verify
```bash
# Confirm the deploy role exists
aws iam get-role --role-name acme-cloud-poc-github-deploy-role --query 'Role.Arn'

# Confirm it's actually wired into cluster RBAC, not just IAM-side
aws eks list-access-entries --cluster-name acme-cloud-poc-eks
```

### The role ARN every service repo's workflow needs
```
arn:aws:iam::338449997393:role/acme-cloud-poc-github-deploy-role
```
Used like this in each service repo's `.github/workflows/deploy.yml`:
```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::338449997393:role/acme-cloud-poc-github-deploy-role
      aws-region: us-east-1
```

### Destroy (end of session)
```bash
cd terraform/iam-oidc && terraform destroy
```

---

## Phase 6 — AWS Load Balancer Controller

### Deploy (depends on vpc + eks)
```bash
cd platform-infrastructure/terraform/alb-controller
terraform init
terraform plan
terraform apply
```
⏱ Takes 1-3 min — mostly Helm waiting for the controller pod to report Ready.

### Verify
```bash
# Both pods should show 1/1 Running
kubectl get pods -n kube-system | grep aws-load-balancer-controller

# Check for clean startup, no crash loops
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -20
```
Real proof it can create ALBs comes later (Phase 8/9) when we deploy a service with an actual `Ingress` resource and watch a real ALB appear in AWS Console.

### Destroy (end of session)
```bash
cd terraform/alb-controller && terraform destroy
```

---

## Troubleshooting we've hit so far

### "authentication mode must be set to API or API_AND_CONFIG_MAP"
EKS clusters default to `CONFIG_MAP` auth mode, which doesn't support IAM Access Entries (needed for OIDC/GitHub Actions RBAC in Phase 5). Fix: add `access_config { authentication_mode = "API_AND_CONFIG_MAP" }` to the cluster resource. **Important**: also explicitly set `bootstrap_cluster_creator_admin_permissions = true` in the same block — leaving it unset makes Terraform think it changed and forces a full cluster + node group replacement (30+ min). Setting it explicitly gives a clean in-place update instead.

### `terraform init` fails mid-download with "connection reset by peer"
Flaky network blip talking to releases.hashicorp.com, not a config issue. Just retry `terraform init` — providers already downloaded are cached, so retry is fast.

---

## Standard order of operations, every session

**Starting work:**
```bash
cd terraform/vpc && terraform apply   # if not already up
cd ../eks && terraform apply           # depends on vpc
cd ../ecr && terraform apply           # independent
cd ../rds && terraform apply           # depends on vpc + eks
cd ../iam-oidc && terraform apply      # depends on eks
cd ../alb-controller && terraform apply # depends on vpc + eks
aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
kubectl get nodes                      # confirm healthy before continuing
```

**Ending work (always do this to avoid ongoing charges):**
```bash
cd terraform/alb-controller && terraform destroy  # first, so nothing hangs onto the ALB
cd ../iam-oidc && terraform destroy   # independent, any order
cd ../rds && terraform destroy                # rds first (depends on eks/vpc)
cd ../ecr && terraform destroy                # independent, any order
cd ../eks && terraform destroy                # eks before vpc
cd ../vpc && terraform destroy                # vpc last
```