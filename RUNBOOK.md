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

## Phase 7 — External Secrets Operator + Secrets Manager wiring

### Deploy (depends on eks + rds + alb-controller — reuses its EKS OIDC provider)
```bash
cd platform-infrastructure/terraform/external-secrets
terraform init
terraform plan
```
**Must apply in 2 steps** — `kubernetes_manifest` resources (SecretStore/ExternalSecret CRDs) fail plan-time validation if the CRDs don't exist in the cluster yet:
```bash
terraform apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
terraform apply
```

### Verify
```bash
kubectl get clustersecretstore
kubectl get externalsecret -n default
kubectl get secret rds-credentials -n default
```
`clustersecretstore` should show `READY: True`. `externalsecret` should show `STATUS: SecretSynced`, `READY: True`. The `secret` should exist with 5 data keys (username, password, dbname, host, port) — this is the real proof credentials flowed from Secrets Manager into a usable K8s Secret.

### Destroy (end of session)
```bash
cd terraform/external-secrets && terraform destroy
```

---

## Phase 8 — backend-service (app repo, not platform-infrastructure)

This is a separate repo. No Terraform here — the app repo only owns code, Dockerfile, K8s manifests, and its own workflow.

### Deploy
Push to `main` — the workflow runs automatically, no manual command needed:
```bash
cd backend-service
git add .
git commit -m "..."
git push
```
Workflow does: OIDC auth (Phase 5 role) → build/push image to ECR (Phase 4) → `kubectl apply` the 3 manifests → wait for rollout.

### Verify
```bash
kubectl get pods -n default
kubectl get deployment backend-service -n default
kubectl get ingress backend-service -n default    # ADDRESS column = real ALB DNS name, proof Phase 6 works end-to-end
```

Test the live endpoint (get the ALB address from the ingress command above):
```bash
curl http://<alb-address>/api/healthz
curl http://<alb-address>/api/readyz     # confirms RDS connectivity, not just pod liveness
curl -X POST http://<alb-address>/api/order -H "Content-Type: application/json" -d '{"item":"widget","quantity":2}'
```

### Destroy
No separate Terraform destroy — deleting the Deployment/Service/Ingress removes the ALB too:
```bash
kubectl delete -f k8s/
```

---

## Dockerfile hardening (backend-service)

Started with single-stage `python:3.12-slim` — Docker Desktop's scanner flagged 1 critical + 2 high vulnerabilities. Switched to a **multi-stage build with a distroless final image**:

- Stage 1 (builder): `python:3.11-slim`, installs deps into `/app/deps`
- Stage 2 (runtime): `gcr.io/distroless/python3-debian12:nonroot` — no shell, no package manager, drastically smaller attack surface

**Key gotcha**: the builder's Python minor version must exactly match distroless's bundled Python (3.11) — `psycopg2` and other compiled C extensions are ABI-tied to a specific Python minor version, so a mismatch causes import failures at container startup, not at build time.

**Debugging without a shell** (since distroless has none):
- Rely on structured logs shipped out of the container, not `docker exec`
- `kubectl debug -it <pod> --image=busybox --target=<container>` attaches a temporary debug container to the same pod namespace without modifying the production image
- Readiness/liveness probes (`/api/healthz`, `/api/readyz`) catch most failures before manual debugging is even needed

---

## EKS node group: max-pods fix (added mid-Phase 7)

Ran into this rebuilding ESO — worth its own section since it touches the `eks/` module directly, not just external-secrets.

**Symptom**: pods stuck `Pending` forever, `kubectl get events` shows `0/2 nodes are available: 2 Too many pods`.

**Root cause**: `t3.micro` nodes (forced by the Free Tier restriction) have a very low kubelet `--max-pods` ceiling, set once at node boot from a static AWS lookup table based on instance type. Enabling VPC CNI prefix delegation (`ENABLE_PREFIX_DELEGATION=true`) raises available IPs but does **not** by itself raise `--max-pods` — that's a separate setting, and it doesn't retroactively apply to already-running nodes either way.

**Real fix**: a custom `aws_launch_template` with AL2023 `nodeadm` user-data that explicitly overrides `--max-pods=110`, referenced by the node group's `launch_template` block. This forces a node group replacement (~15-20 min) since AMI/bootstrap config changed. Combined this with bumping `node_desired_size` 2 → 3 in the same apply.

```bash
# after eks/main.tf + variables.tf updated with launch template + max-pods
cd terraform/eks
terraform plan   # expect: aws_launch_template create, aws_eks_node_group replace
terraform apply  # ~15-20 min, node group fully replaces

# verify it worked
kubectl get nodes                       # should show 3 nodes Ready
kubectl describe node <name> | grep -A3 "Allocatable"   # pods: should now read 110
```

**Production note**: prefix delegation is standard practice on every node size in real production, not just a POC fix. What's not standard is running `t3.micro` at all — that's purely a Free Tier account restriction. A real cluster sizes nodes for actual workload requirements and lets Cluster Autoscaler (Phase 11) handle horizontal scaling; prefix delegation just quietly improves IP efficiency underneath, regardless of instance size.

---

## Troubleshooting we've hit so far

### "authentication mode must be set to API or API_AND_CONFIG_MAP"
EKS clusters default to `CONFIG_MAP` auth mode, which doesn't support IAM Access Entries (needed for OIDC/GitHub Actions RBAC in Phase 5). Fix: add `access_config { authentication_mode = "API_AND_CONFIG_MAP" }` to the cluster resource. **Important**: also explicitly set `bootstrap_cluster_creator_admin_permissions = true` in the same block — leaving it unset makes Terraform think it changed and forces a full cluster + node group replacement (30+ min). Setting it explicitly gives a clean in-place update instead.

### `terraform init` fails mid-download with "connection reset by peer"
Flaky network blip talking to releases.hashicorp.com, not a config issue. Just retry `terraform init` — providers already downloaded are cached, so retry is fast.

### `kubernetes_manifest` resource fails: "no matches for kind X in group Y (CRD may not be installed)"
Terraform validates `kubernetes_manifest` resources against the cluster's live API schema at plan time — but the CRD (from a Helm chart in the same apply) doesn't exist yet on a first-ever apply. Fix: apply the Helm release first with `-target`, then apply everything else in a second pass. Not a bug, this is standard/expected Terraform + CRD behavior.

### `0/2 nodes are available: 2 Too many pods`
See "EKS node group: max-pods fix" section above — instance-type pod-count ceiling, not a resource (CPU/memory) shortage. Confirm with `kubectl describe nodes | grep -A5 "Allocated resources"` (memory/CPU usage will look low) vs `kubectl get events -n <namespace>` (will explicitly say "Too many pods").

### `SecretStore` admission webhook: "namespace should either be empty or match the namespace of the SecretStore"
Happens when the ServiceAccount used for auth lives in a different namespace than the `SecretStore` resource itself — namespaced `SecretStore` only allows same-namespace ServiceAccount references. Fix: use `ClusterSecretStore` instead (cluster-scoped, no `namespace` in its own metadata), which is explicitly designed to reference a ServiceAccount from any namespace.

### `curl <alb>/api/healthz` returns `{"detail":"Not Found"}`
ALB forwards the full request path (including the `/api` prefix from the Ingress rule) straight to the pod — it does not strip the prefix like some ingress controllers do. If the app's routes are defined without the `/api` prefix (e.g. just `/healthz`), every request 404s. Fix: mount all app routes under an `APIRouter(prefix="/api")` so the app's own paths match what the Ingress forwards. Also update K8s liveness/readiness probe paths and the ALB `healthcheck-path` annotation to match, since those hit the pod directly.

---

## One-time setup (do this only once, ever)

See `Must-Manual-setup.md` for:
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
cd ../ecr && terraform apply           # independent
cd ../rds && terraform apply           # depends on vpc + eks
cd ../iam-oidc && terraform apply      # depends on eks
cd ../alb-controller && terraform apply # depends on vpc + eks
cd ../external-secrets && terraform apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
cd ../external-secrets && terraform apply   # 2nd pass, picks up CRD manifests
aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
kubectl get nodes                      # confirm healthy before continuing
```

**Ending work (always do this to avoid ongoing charges):**
```bash
cd terraform/external-secrets && terraform destroy  # first
cd ../alb-controller && terraform destroy  # so nothing hangs onto the ALB
cd ../iam-oidc && terraform destroy   # independent, any order
cd ../rds && terraform destroy                # rds first (depends on eks/vpc)
cd ../ecr && terraform destroy                # independent, any order
cd ../eks && terraform destroy                # eks before vpc
cd ../vpc && terraform destroy                # vpc last
```