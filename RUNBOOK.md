# RUNBOOK — how to run this project

This is the short version — the exact steps to get any environment up or down. For "why did X break and how was it fixed," see `Debug.md` instead; this file stays focused on "what do I run right now."

---

## Phase 1 — One-time setup

Before anything else, do this once:

1. Follow **`Must-Manual-setup.md`** — AWS account, IAM user, AWS CLI, `aws configure`, S3 bucket + DynamoDB table for Terraform state.
2. Install Terragrunt:
   ```bash
   brew install terragrunt
   terragrunt --version
   ```

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
                  # iam-oidc → alb-controller → external-secrets, then connects
                  # kubectl and shows node/pod health

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

cd ../external-secrets
terragrunt apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
terragrunt apply

kubectl get nodes
kubectl get pods -n default
```

### Manual — tearing an environment down (shown for `poc`)

```bash
cd platform-infrastructure/live/poc

# Delete the app Ingresses first, while the ALB controller can still react —
# otherwise the ALB gets orphaned and vpc destroy hangs waiting on its ENIs
kubectl delete ingress backend-service -n default --ignore-not-found=true
kubectl delete ingress frontend-service -n default --ignore-not-found=true

cd external-secrets && terragrunt destroy
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