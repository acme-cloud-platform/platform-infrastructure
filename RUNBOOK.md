# RUNBOOK — how to run this project

This is our command reference. Every command we've actually run, grouped by
phase, so we (or anyone else) can rebuild or verify the whole thing from
scratch without re-figuring things out.

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

## Troubleshooting we've hit so far

### "InvalidParameterCombination - not eligible for Free Tier"
New AWS accounts get a temporary restriction blocking non-Free-Tier EC2 instance types. Check what's allowed:
```bash
aws ec2 describe-instance-types \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'InstanceTypes[].InstanceType'
```
Fix: set `node_instance_type` in `terraform/eks/variables.tf` to a Free Tier type (`t3.micro` / `t2.micro`), then `terraform apply` again — Terraform auto-detects the failed (tainted) node group and recreates it.

### Node group stuck in "CREATING" for a long time
Normal — first-time node group creation is the slowest step (15-25 min). Check real status instead of guessing:
```bash
aws eks describe-nodegroup --cluster-name acme-cloud-poc-eks --nodegroup-name acme-cloud-poc-nodes --query 'nodegroup.status'
```
Only worry if this returns `CREATE_FAILED` — check the node group's **Health** section in the AWS Console for the actual error message.

### `terraform apply` warning: "dynamodb_table is deprecated"
Harmless for now, still works. Future cleanup: migrate to `use_lockfile` parameter. Not urgent.

---

## One-time setup (do this only once, ever)

See `terraform/vpc/README-BACKEND-SETUP.md` for:
- Creating the AWS account + IAM user
- Installing AWS CLI + Terraform
- `aws configure` setup
- Creating the S3 bucket + DynamoDB table for Terraform remote state

---

## Standard order of operations, every session

**Starting work:**
```bash
cd terraform/vpc && terraform apply   # if not already up
cd ../eks && terraform apply           # depends on vpc
aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
kubectl get nodes                      # confirm healthy before continuing
```

**Ending work (always do this to avoid ongoing charges):**
```bash
cd terraform/eks && terraform destroy   # eks first
cd ../vpc && terraform destroy           # vpc second
```