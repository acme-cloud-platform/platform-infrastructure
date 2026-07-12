# RUNBOOK — how to run this project

This is our command reference. Every command we've actually run, grouped by
phase, so we (or anyone else) can rebuild or verify the whole thing from
scratch without re-figuring things out.

---

## Phase 1 - Must-Manul-Setup.md

## One-time setup (do this only once, ever)

See `Must-Manual-setup.md` for:
- Creating the AWS account + IAM user
- Installing AWS CLI + Terraform
- `aws configure` setup
- Creating the S3 bucket + DynamoDB table for Terraform remote state

---

## Terragrunt basics (read this once, before deploying any module below)

**Since Phase 10, all Terraform commands below run through `terragrunt`, not `terraform` directly.** The old flat `terraform/<module>/` folders are gone — replaced by `modules/` (environment-agnostic resource logic) + `live/<env>/<module>/` (tiny per-environment wrappers). Three environments exist and are all running: `poc`, `dev`, `qa`.

**Every command below is shown for `poc` — to run it against `dev` or `qa` instead, just swap the path:**
```bash
cd platform-infrastructure/live/poc/vpc    # poc
cd platform-infrastructure/live/dev/vpc    # dev — same commands, different folder
cd platform-infrastructure/live/qa/vpc     # qa — same commands, different folder
```

**Always use `terragrunt`, never plain `terraform`, inside any `live/*/*/` folder.** `terragrunt init` sets up an isolated `.terragrunt-cache/` per module — a bare `terraform plan` run afterward looks at your actual working directory (which has no providers downloaded there) and fails with "Required plugins are not installed". This isn't a bug, just a command mixup — always `terragrunt <command>`.

Install Terragrunt once, if not already done:
```bash
brew install terragrunt
terragrunt --version
```

---

## Phase 2 — VPC / Networking

### Deploy
```bash
cd platform-infrastructure/live/poc/vpc
terragrunt init
terragrunt plan
terragrunt apply
```

### Verify
```bash
# Confirm VPC exists
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=acme-cloud-poc-vpc"

# Confirm subnets
aws ec2 describe-subnets --filters "Name=tag:Name,Values=acme-cloud-poc-*"
```
Or just check AWS Console → VPC → Your VPCs → Resource map tab (shows subnets, route tables, IGW, NAT visually). For `dev`/`qa`, swap the `poc` tag filter values for `acme-cloud-dev-*` / `acme-cloud-qa-*`.

### Destroy (end of session, to stop billing)
```bash
cd platform-infrastructure/live/poc/vpc
terragrunt destroy
```

---

## Phase 3 — EKS cluster + node group

### Deploy
```bash
cd platform-infrastructure/live/poc/eks
terragrunt init
terragrunt plan
terragrunt apply
```
⏱ Cluster creation: ~10 min. Node group creation: ~5-15 min (longer if instance type gets rejected — see troubleshooting below). Requires `vpc` (previous step) already applied — `terragrunt`'s `dependency` block reads its outputs automatically, no manual wiring needed.

### Connect kubectl to the cluster
```bash
aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
# for dev:  --name acme-cloud-dev-eks
# for qa:   --name acme-cloud-qa-eks
```
`kubectl` only ever points at one cluster at a time — switch contexts with `kubectl config use-context <context-name>` or just re-run `update-kubeconfig` for whichever environment you're working in. `kubectl config get-contexts` lists all clusters you've connected to so far.

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
cd platform-infrastructure/live/poc/eks
terragrunt destroy
```
Then destroy the VPC too (eks depends on vpc, so eks must go first):
```bash
cd ../vpc
terragrunt destroy
```

---

## Phase 4 — ECR repos + RDS

### Deploy ECR (no dependencies — can run any time)
```bash
cd platform-infrastructure/live/poc/ecr
terragrunt init
terragrunt plan
terragrunt apply
```

### Deploy RDS (depends on vpc + eks — both must be up first)
```bash
cd ../rds
terragrunt init
terragrunt plan
terragrunt apply
```

### Verify ECR
```bash
aws ecr describe-repositories --query 'repositories[].repositoryName'
```
Shows all environments' repos together (e.g. `acme-cloud-poc-backend`, `acme-cloud-dev-backend`, `acme-cloud-qa-backend`) since ECR is listed account-wide, not per-environment — filter by name prefix if you only want one environment's repos.

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
cd live/poc/rds && terragrunt destroy   # rds first (depends on eks/vpc)
cd ../ecr && terragrunt destroy          # ecr independent, any order is fine
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
Fix: set `node_instance_type` in `live/<env>/eks/terragrunt.hcl`'s `inputs` block to a Free Tier type (`t3.micro` / `t2.micro`), then `terragrunt apply` again — Terraform auto-detects the failed (tainted) node group and recreates it. Same fix pattern applies to `db_instance_class` in `live/<env>/rds/terragrunt.hcl` if RDS hits the same restriction. Note this now lives in the `live/` wrapper's `inputs`, not in `modules/eks/variables.tf` — the module's `variable` block just defines the type and an unused fallback default; the real per-environment value is always set in `live/<env>/`.

### Node group stuck in "CREATING" for a long time
Normal — first-time node group creation is the slowest step (15-25 min). Check real status instead of guessing:
```bash
aws eks describe-nodegroup --cluster-name acme-cloud-poc-eks --nodegroup-name acme-cloud-poc-nodes --query 'nodegroup.status'
```
Only worry if this returns `CREATE_FAILED` — check the node group's **Health** section in the AWS Console for the actual error message.

### `terragrunt apply` warning: "dynamodb_table is deprecated"
Harmless for now, still works. Future cleanup: migrate to `use_lockfile` parameter in `live/terragrunt.hcl`'s `remote_state` block. Not urgent.

### Bare `terraform plan` fails with "Required plugins are not installed" right after `terragrunt init` succeeded
Ran the wrong binary — `terragrunt init` sets up an isolated provider cache under `.terragrunt-cache/`, invisible to a plain `terraform` command run from the same folder. Always use `terragrunt plan` / `terragrunt apply` inside any `live/*/*/` folder, never bare `terraform`.

### `WARN Using terragrunt.hcl as the root of Terragrunt configurations is an anti-pattern`
Cosmetic warning from newer Terragrunt versions, nudging toward renaming `live/terragrunt.hcl` → `live/root.hcl` in a future cleanup. Doesn't block anything today — safe to ignore for now.

---

## Phase 5 — IAM OIDC provider for GitHub Actions

### Deploy (depends on eks — access entries need the cluster to exist)
```bash
cd platform-infrastructure/live/poc/iam-oidc
terragrunt init
terragrunt plan
terragrunt apply
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
For `dev`/`qa`, use `acme-cloud-dev-github-deploy-role` / `acme-cloud-qa-github-deploy-role` instead — each environment has its own deploy role, pointed at its own cluster via its own EKS Access Entry (see README.md Phase 5 for the full breakdown).

### Destroy (end of session)
```bash
cd live/poc/iam-oidc && terragrunt destroy
```

---

## Phase 6 — AWS Load Balancer Controller

### Deploy (depends on vpc + eks)
```bash
cd platform-infrastructure/live/poc/alb-controller
terragrunt init
terragrunt plan
terragrunt apply
```
⏱ Takes 1-3 min — mostly Helm waiting for the controller pod to report Ready.

### Verify
```bash
# Both pods should show 1/1 Running
kubectl get pods -n kube-system | grep aws-load-balancer-controller

# Check for clean startup, no crash loops
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -20
```
Real proof it can create ALBs comes later (Phase 8/9) when we deploy a service with an actual `Ingress` resource and watch a real ALB appear in AWS Console. Remember `kubectl` is pointed at whichever cluster you last ran `update-kubeconfig` for — double check `kubectl config current-context` if verifying a specific environment.

### Destroy (end of session)
```bash
cd live/poc/alb-controller && terragrunt destroy
```

---

## Phase 7 — External Secrets Operator + Secrets Manager wiring

### Deploy (depends on eks + rds + alb-controller — reuses its EKS OIDC provider)
```bash
cd platform-infrastructure/live/poc/external-secrets
terragrunt init
terragrunt plan
```
**Still must apply in 2 steps on a first-ever apply** — Terragrunt's `dependency` blocks (on `eks`, `rds`, `alb-controller`) only solve *cross-module* ordering, resolving those modules' outputs before this one runs. They don't touch the *separate* problem inside this module: `helm_release.eso` (which installs the ExternalSecrets CRDs) and the `kubernetes_manifest` resources (`ClusterSecretStore`, `ExternalSecret`) live in the same `modules/external-secrets/main.tf`, same apply — and Terraform validates `kubernetes_manifest` against the cluster's live API schema at plan time, before the CRDs exist yet on a first-ever run. Same fix as before, just with `terragrunt` instead of `terraform`:
```bash
terragrunt apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
terragrunt apply
```
On any *later* apply (CRDs already installed from the first run), a single `terragrunt apply` is fine — this 2-step dance is only required the very first time this module is applied in a given environment.

### Verify
```bash
kubectl get clustersecretstore
kubectl get externalsecret -n default
kubectl get secret rds-credentials -n default
```
`clustersecretstore` should show `READY: True`. `externalsecret` should show `STATUS: SecretSynced`, `READY: True`. The `secret` should exist with 5 data keys (username, password, dbname, host, port) — this is the real proof credentials flowed from Secrets Manager into a usable K8s Secret.

### Destroy (end of session)
```bash
cd live/poc/external-secrets && terragrunt destroy
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

## Phase 9 — frontend-service (second app repo)

Separate repo again, same pattern as Phase 8. Key difference: shares the **same ALB** as backend-service via IngressGroup, instead of provisioning a second one.

### Deploy
Push order matters the first time: apply backend's updated Ingress (with matching `group.name`) **before** frontend's, so the shared IngressGroup forms cleanly.
```bash
cd backend-service
git add k8s/ingress.yaml
git commit -m "Merge into shared ALB IngressGroup with frontend-service"
git push
# wait for that workflow to finish and confirm healthy

cd ../frontend-service
git add .
git commit -m "..."
git push
```

### Verify
```bash
kubectl get pods -n default
kubectl get ingress -n default    # both frontend-service and backend-service should show the SAME ADDRESS
```
```bash
curl http://<shared-alb-address>/            # frontend HTML
curl http://<shared-alb-address>/api/healthz # backend, same ALB, different path
```
Open the ALB address in a browser — real test of the whole platform, submit an order through the actual UI.

### Destroy
```bash
kubectl delete -f k8s/
```
Only destroy this AFTER backend's, or delete both together — since they share one ALB, deleting one Ingress just drops its rules from the group; the ALB itself only tears down once no Ingress in the group remains.

---

## Phase 10 — notification-service (third app repo — background worker)

Separate repo again. No `Service`, no `Ingress` — this is a background worker only, so there's nothing for a Service or Ingress to route to. Just a `Deployment`.

### Deploy
Same pattern as Phases 8/9 — push to `main`, the workflow runs automatically, no manual command needed:
```bash
cd notification-service
git add .
git commit -m "..."
git push
```
Workflow does: OIDC auth (Phase 5 role, this repo was trusted from day one) → build/push image to ECR (`acme-cloud-poc-notification`) → substitute the image into `k8s/deployment.yaml` → `kubectl apply` → wait for rollout.

### Verify
```bash
# Should show 1/1 Running — no Service, no Ingress to check, this pod isn't reachable from outside
kubectl get pods -n default | grep notification-service

# Real proof it's working: tail the logs and place a test order from another terminal
kubectl logs deployment/notification-service --tail=20 -f
```
In a second terminal, place an order through the live app (same shared ALB as Phase 8/9):
```bash
curl -X POST http://<shared-alb-address>/api/order \
  -H "Content-Type: application/json" \
  -d '{"item":"phase10-test","quantity":1}'
```
Within one poll cycle (≤15s), the `kubectl logs -f` terminal should print a line like:
```
2026-07-12 07:57:27,437 INFO Notification sent: order #5 — phase10-test x1 (placed at 2026-07-12 07:57:16.935636+00:00)
```
That line — a new order placed through `backend-service`, picked up by `notification-service` polling the same database — is the actual proof this phase works, not just that the pod is `Running`.

### Confirm zero platform-infrastructure changes (the actual point of this phase)
```bash
cd platform-infrastructure
git log --oneline --since="whenever Phase 9 finished"   # should show no commits touching modules/, live/, helm/, or kubernetes/ for this service
git diff HEAD~<phase-9-commit>..HEAD -- modules/ live/ helm/ kubernetes/   # should be empty
```

### Destroy
```bash
kubectl delete -f k8s/deployment.yaml
```
No `Service`/`Ingress` to clean up, and nothing here affects the shared ALB from Phase 8/9 — deleting this Deployment only stops the worker.

---

## Dockerfile hardening (notification-service)

Same distroless pattern as backend-service (Phase 8) — multi-stage build, `python:3.11-slim` builder pinned to match `gcr.io/distroless/python3-debian12:nonroot`'s bundled Python exactly (the same `psycopg2` ABI-version gotcha applies here as it did for backend-service).

Key difference from backend-service: **no exposed port, no web server at all** — this container's `CMD` is just `["app/worker.py"]`, an infinite polling loop with no HTTP listener. Since nothing external ever connects to this pod, there's no `EXPOSE`, no readiness/liveness HTTP probe, and no `Service`/`Ingress` manifests in `k8s/` — just a bare `Deployment`.

**Debugging this one without a shell** (same distroless constraint as backend-service): since there's no HTTP endpoint to curl or probe, `kubectl logs -f` is the primary tool — the worker logs every poll-cycle action (notifications sent, errors + retries) via Python's standard `logging` module, which is what you actually watch to confirm it's alive and working, rather than a `/healthz`-style check.

---

## Dockerfile hardening (frontend-service)

Same distroless approach as backend, but nginx has no official distroless equivalent, so static files are served by a ~40-line zero-dependency Node HTTP server (`server.js`, built-in `http`/`fs` modules only) instead:

- Stage 1 (builder): `node:20-slim`, runs `npm install` + `vite build`
- Stage 2 (runtime): `gcr.io/distroless/nodejs20-debian12:nonroot`, copies only `dist/` + `server.js`

**Real issue hit**: used `ENTRYPOINT ["server.js"]` in the final stage, which **overrides** the distroless base image's existing `ENTRYPOINT ["/nodejs/bin/node"]` instead of combining with it. Container tried to exec `server.js` directly as a binary → crash loop with `exec: "server.js": executable file not found in $PATH`. Fix: use `CMD ["server.js"]` instead — this combines with the base image's ENTRYPOINT, producing the correct effective command `node server.js`.

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

Ran into this rebuilding ESO — worth its own section since it touches the `eks/` module directly, not just external-secrets. **Note: this happened before the Phase 10 Terragrunt restructure, so the commands below reflect the old `terraform/eks` path as actually run at the time. On the current structure, the equivalent commands are `cd live/poc/eks && terragrunt plan` / `terragrunt apply` — the underlying fix (custom launch template, explicit `--max-pods=110`) lives unchanged in `modules/eks/` today.**

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

### `terragrunt init` fails mid-download with "connection reset by peer"
Flaky network blip talking to releases.hashicorp.com, not a config issue. Just retry `terragrunt init` — providers already downloaded are cached, so retry is fast.

### `kubernetes_manifest` resource fails: "no matches for kind X in group Y (CRD may not be installed)"
Terraform validates `kubernetes_manifest` resources against the cluster's live API schema at plan time — but the CRD (from a Helm chart in the same apply) doesn't exist yet on a first-ever apply. Fix: apply the Helm release first with `-target`, then apply everything else in a second pass. Not a bug, this is standard/expected Terraform + CRD behavior.

### `0/2 nodes are available: 2 Too many pods`
See "EKS node group: max-pods fix" section above — instance-type pod-count ceiling, not a resource (CPU/memory) shortage. Confirm with `kubectl describe nodes | grep -A5 "Allocated resources"` (memory/CPU usage will look low) vs `kubectl get events -n <namespace>` (will explicitly say "Too many pods").

### `SecretStore` admission webhook: "namespace should either be empty or match the namespace of the SecretStore"
Happens when the ServiceAccount used for auth lives in a different namespace than the `SecretStore` resource itself — namespaced `SecretStore` only allows same-namespace ServiceAccount references. Fix: use `ClusterSecretStore` instead (cluster-scoped, no `namespace` in its own metadata), which is explicitly designed to reference a ServiceAccount from any namespace.

### `curl <alb>/api/healthz` returns `{"detail":"Not Found"}`
ALB forwards the full request path (including the `/api` prefix from the Ingress rule) straight to the pod — it does not strip the prefix like some ingress controllers do. If the app's routes are defined without the `/api` prefix (e.g. just `/healthz`), every request 404s. Fix: mount all app routes under an `APIRouter(prefix="/api")` so the app's own paths match what the Ingress forwards. Also update K8s liveness/readiness probe paths and the ALB `healthcheck-path` annotation to match, since those hit the pod directly.

### `vite build` fails: "Could not resolve entry module index.html"
Vite requires `index.html` at the project root (same level as `package.json`), not inside `src/`. Usually means the file either never got committed or was placed in the wrong folder. Check with `git log --oneline --all -- index.html` — if empty, it was never committed.

### Distroless container crash loops: `exec: "server.js": executable file not found in $PATH`
Caused by setting `ENTRYPOINT ["server.js"]` in a Dockerfile whose base image (`gcr.io/distroless/nodejs*`) already has its own `ENTRYPOINT` baked in (pointing at the `node` binary). Setting `ENTRYPOINT` again **overrides** the base image's instead of combining with it, so Docker tries to execute the script directly as a binary. Fix: use `CMD [...]` instead of `ENTRYPOINT [...]` for the script — `CMD` combines with the base image's existing `ENTRYPOINT`, producing the correct `node server.js`.

### `notification-service` pod runs but `kubectl logs` never shows a "Notification sent" line
Check, in order: (1) is `notification_state` actually being created — connect and `SELECT * FROM notification_state;`, confirm it has a row with `id=1`; (2) is `last_notified_order_id` already ahead of the newest order (e.g. left over from an earlier test run against the same DB) — if so, older orders will never re-trigger, only genuinely new ones will; (3) confirm the pod is actually using the same `rds-credentials` Secret backend-service uses — `kubectl describe pod -n default -l app=notification-service` and check the env section resolves to the same `host`/`dbname` as backend-service's pod. This is a shared-database polling design, so almost every "it's silent" symptom traces back to state in the DB, not the pod itself.

---

## Standard order of operations, every session

Shown for `poc` — repeat the identical sequence from `live/dev/` or `live/qa/` to bring up/tear down those environments; the order and dependency logic is the same for all three.

**Starting work:**
```bash
cd platform-infrastructure/live/poc

cd vpc && terragrunt apply               # if not already up
cd ../eks && terragrunt apply             # depends on vpc
cd ../ecr && terragrunt apply             # independent
cd ../rds && terragrunt apply             # depends on vpc + eks
cd ../iam-oidc && terragrunt apply        # depends on eks
cd ../alb-controller && terragrunt apply  # depends on vpc + eks
cd ../external-secrets && terragrunt apply -target=helm_release.eso -target=aws_iam_role_policy.eso_secrets_read -target=kubernetes_service_account.eso
cd ../external-secrets && terragrunt apply   # 2nd pass, picks up CRD-dependent manifests — only needed on this environment's first-ever apply

aws eks update-kubeconfig --name acme-cloud-poc-eks --region us-east-1
kubectl get nodes                      # confirm healthy before continuing
kubectl get pods -n default            # confirm backend-service, frontend-service, notification-service all Running
```
The `external-secrets` 2-step apply is still required the first time this module runs in a given environment — Terragrunt's `dependency` blocks only fixed *cross-module* ordering (this module correctly waiting on `eks`/`rds`/`alb-controller`'s outputs); the CRD-before-manifest problem is *inside* this one module and Terragrunt doesn't change that. See Phase 7 above for the full explanation. On repeat applies (CRDs already installed), a single `terragrunt apply` is enough.

**Ending work (always do this to avoid ongoing charges):**
```bash
cd platform-infrastructure/live/poc

cd external-secrets && terragrunt destroy  # first
cd ../alb-controller && terragrunt destroy  # so nothing hangs onto the ALB
cd ../iam-oidc && terragrunt destroy   # independent, any order
cd ../rds && terragrunt destroy                # rds first (depends on eks/vpc)
cd ../ecr && terragrunt destroy                # independent, any order
cd ../eks && terragrunt destroy                # eks before vpc
cd ../vpc && terragrunt destroy                # vpc last
```
Running all three environments simultaneously (`poc` + `dev` + `qa`) means 3x the running cost — remember to run this teardown sequence for every environment you brought up, not just one.