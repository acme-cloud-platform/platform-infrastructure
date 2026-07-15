# RUNBOOK — how to run this project

This is the short version — the exact steps to get any environment up or down. For "why did X break and how was it fixed," see `Debug.md` instead; this file stays focused on "what do I run right now."

---

## Phase 1 — One-time setup

Before anything else, do this once:

1. Follow **`Must-Manual-setup.md`** — AWS account, IAM user, Terragrunt, AWS CLI, `aws configure`, S3 bucket + DynamoDB table for Terraform state.


That's it — everything else below is automated.

---

## Bringing an environment up or down

Three environments exist: `poc`, `dev`, `qa`. Each has its own pair of scripts at the repo root:

| Environment | Bring up | Tear down |
|---|---|---|
| poc | `./up-poc.sh` | `./down-poc.sh` |
| dev | `./up-dev.sh` | `./down-dev.sh` |
| qa | `./up-qa.sh` | `./down-qa.sh` |

```bash
cd platform-infrastructure
chmod +x up-poc.sh down-poc.sh up-dev.sh down-dev.sh up-qa.sh down-qa.sh   # once, if not already executable

./up-poc.sh      # brings the whole poc environment up: vpc → eks → ecr → rds →
                  # iam-oidc → alb-controller → cluster-autoscaler → ebs-csi →
                  # external-secrets → monitoring, then connects kubectl and
                  # shows node/pod health

./down-poc.sh    # tears poc down in reverse order — asks you to type "poc" to confirm first
```

Each script handles the full dependency order, connects `kubectl` to the right cluster automatically, force-deletes the RDS secret on teardown so the next `up` doesn't hit a naming conflict, and auto-recovers from a stale state lock if a previous run got interrupted.

**Use the same two scripts for `dev` and `qa`** — just swap `poc` for `dev`/`qa` in the filename, everything else works identically.

### Deploying the 3 application services

Once an environment's infrastructure is up, the app repos deploy themselves via CI/CD:

```bash
# in backend-service, frontend-service, or notification-service
git push origin main   # deploys to poc
git push origin dev    # deploys to dev
git push origin qa     # deploys to qa
```

Each repo's GitHub Actions workflow resolves which environment it's deploying to from the branch name, and picks the matching ECR repo / EKS cluster / IAM role automatically. See `README.md` Phase 5/8/9/10 for how that trust chain works.

---

## Testing monitoring and cluster-autoscaler

Two scripts at the repo root, `chmod +x` them once same as the up/down scripts.

### Test 1 — Monitoring (Prometheus + Grafana)

```bash
./test1-monitoring.sh
```

Prints pod/PVC health and your Grafana admin password, then walks you through the manual browser steps. Short version if you just want the commands:

**Get the Grafana password:**
```bash
kubectl -n monitoring get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d
echo
```
Username is always `admin`.

**Check Prometheus is actually scraping (not just running):**
```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
```
Open `http://localhost:9090/targets` — every target should show `UP` (green). If anything is red/down, Prometheus isn't collecting from it.

**Open Grafana:**
```bash
kubectl -n monitoring port-forward svc/grafana 3000:80
```
Open `http://localhost:3000`, log in with `admin` + the password above.

**Add Prometheus as a data source:**
Connections → Data sources → Add data source → Prometheus →
URL: `http://prometheus-server.monitoring.svc.cluster.local` → Save & Test.
Should say "Successfully queried the Prometheus API."

**Import a ready-made dashboard:**
Dashboards → New → Import → paste ID `1860` (Node Exporter Full, the standard community dashboard) → pick your Prometheus data source → Import.
You should see live CPU/memory/disk/network graphs for all 3 nodes. If you see real moving graphs (not "No data"), monitoring is confirmed working end to end.

### Test 2 — Cluster Autoscaler

```bash
./test2-cluster-autoscaler.sh [deployment-name] [namespace] [replica-count]
# defaults: backend-service, default namespace, 150 replicas
```

**Important — this tests node scaling, not load handling.** Cluster-autoscaler reacts to *unschedulable pods*, not to HTTP traffic. Tools like `hey` generate load, but load alone won't add pods unless an HPA is watching CPU/memory and increasing replica count — and that needs `metrics-server` installed, which this project doesn't have yet. So the script scales replica count directly with `kubectl scale`, which is the real trigger cluster-autoscaler responds to. `hey` is still useful separately, just for confirming the service handles concurrent requests well — not for this test.

What it does:
1. Scales the deployment up to 150 replicas (or your override) so pods can't all fit on current nodes.
2. Polls node count for up to 5 minutes, confirms a new node appeared.
3. Scales back down to the original replica count.

**Scale-down is not instant, by design** (avoids flapping under bursty load). After scaling back down, expect the extra node(s) to disappear **10–20 minutes later**, not immediately:
- `scale-down-delay-after-add` (10 min): no scale-down is even considered until 10 min after any scale-up.
- `scale-down-unneeded-time` (10 min): a node must then sit underutilized for 10 more minutes before removal.

Watch it happen live in two terminals:
```bash
kubectl get nodes -w
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler -f
```

If node count goes up when you scale up, and back down ~10-20 min after you scale down — cluster-autoscaler is confirmed working correctly.

---

## ⬇️ If the scripts don't work on your system, use the manual method below

The scripts are just automation — every step they run is a plain `terragrunt` command you can run yourself in the same order. Use this if your shell/OS doesn't support the scripts, or you just want to run one module at a time.

### Manual — bringing an environment up (shown for `poc`; swap the folder for `dev`/`qa`)

```bash
cd platform-infrastructure/live/poc

cd vpc && terragrunt apply
cd ../eks && terragrunt apply

aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1

cd ../ecr && terragrunt apply
cd ../rds && terragrunt apply
cd ../iam-oidc && terragrunt apply
cd ../alb-controller && terragrunt apply
cd ../cluster-autoscaler && terragrunt apply
cd ../ebs-csi && terragrunt apply

cd ../external-secrets
terragrunt apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
terragrunt apply

cd ../monitoring && terragrunt apply

kubectl get nodes
kubectl get pods -n default
kubectl get pods -n kube-system
kubectl get pods -n monitoring
```

### Manual — tearing an environment down (shown for `poc`)

```bash
cd platform-infrastructure/live/poc

# Delete the app Ingresses first, while the ALB controller can still react —
# otherwise the ALB gets orphaned and vpc destroy hangs waiting on its ENIs
kubectl delete ingress backend-service -n default --ignore-not-found=true
kubectl delete ingress frontend-service -n default --ignore-not-found=true

cd external-secrets && terragrunt destroy

# monitoring before ebs-csi: Prometheus's PVC is a real EBS volume — destroy
# it while the CSI driver that manages it still exists, or the volume orphans
cd ../monitoring && terragrunt destroy
cd ../cluster-autoscaler && terragrunt destroy
cd ../ebs-csi && terragrunt destroy

cd ../alb-controller && terragrunt destroy
cd ../iam-oidc && terragrunt destroy
cd ../rds && terragrunt destroy

# Force-delete the secret so the next "up" can recreate it with the same name
aws secretsmanager delete-secret --secret-id acme-cloud-poc-rds-credentials --force-delete-without-recovery --region us-east-1

cd ../ecr && terragrunt destroy
cd ../eks && terragrunt destroy
cd ../vpc && terragrunt destroy
```

**Always use `terragrunt`, never plain `terraform`, inside any `live/*/*/` folder** — `terragrunt init` sets up its own isolated provider cache; a bare `terraform` command run from the same folder won't find it.

If any `terragrunt apply`/`destroy` fails with "Error acquiring the state lock," see `Debug.md`.
