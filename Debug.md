# Debug.md

Real issues hit while building this platform, and how they were fixed. Organized by phase — check here first when something breaks that looks similar.

---

## Phase 3 — EKS: pods stuck `Pending`, "Too many pods"

**Symptom:** New pods stuck `Pending`. `kubectl describe pod` showed `0/2 nodes available: Too many pods`. `kubectl describe nodes` showed low CPU/memory usage even though pods couldn't schedule.

**Cause:** AWS EKS doesn't limit pods-per-node by CPU/memory alone — the kubelet also enforces `--max-pods`, a hard ceiling based on how many IP addresses the instance's ENIs can hand out. `t3.micro` has very few ENI slots, so by default it can only host a handful of pods (well under 10) — a **networking limit, not a resource limit**.

**Fix (2 parts, both needed):**
1. **VPC CNI Prefix Delegation** — set `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` on the VPC CNI addon. Lets the CNI hand out `/28` IP prefixes per ENI slot instead of one IP at a time, at no extra EC2 cost. Standard practice on every production EKS cluster regardless of node size.
2. **Explicit `--max-pods=110`** — prefix delegation alone isn't enough, because kubelet's `--max-pods` is calculated once at node boot from a static AWS lookup table keyed on instance type; it doesn't know prefix delegation happened. Fixed with a custom `aws_launch_template` using the AL2023 `nodeadm` bootstrap format, explicitly setting `kubelet.flags: ["--max-pods=110"]` in the NodeConfig.

**Side effect:** changing the launch template forces a node group replacement (~15-20 min). Expected, not an error.

**Also bumped:** `node_desired_size` 2 → 3, for headroom for controller pods (ALB Controller, ESO, CoreDNS, kube-proxy, aws-node) plus application pods.

**Production note:** `t3.micro` itself is only in this build because of AWS Free Tier account restrictions — a real cluster would size nodes for actual workload needs (e.g. `m5.large`+), still enable prefix delegation regardless, and use Cluster Autoscaler (Phase 11) instead of a fixed `desired_size`.

---

## Phase 8 — backend-service

### Issue 1: `/api/*` routes returning 404

**Symptom:** ALB → pod requests to `/api/orders` etc. returned 404, even though the pod was healthy.

**Cause:** ALB forwards the full path including `/api`, but the FastAPI routes weren't prefixed with `/api` — so the app was listening on `/orders`, not `/api/orders`.

**Fix:** mounted all routes under `APIRouter(prefix="/api")`.

### Issue 2: Container flagged with critical/high CVEs

**Symptom:** Docker's image scanner flagged the initial `python:3.12-slim` single-stage image with 1 critical + 2 high severity CVEs.

**Fix:** rebuilt as a multi-stage image — `python:3.11-slim` builder → `gcr.io/distroless/python3-debian12:nonroot` runtime. Distroless has no shell, no package manager, drastically smaller attack surface.

**Trade-off:** no shell means no `kubectl exec -it ... sh` for debugging. Use structured logs, or attach a temporary debug sidecar: `kubectl debug --image=busybox <pod>` — doesn't modify the production image.

---

## Phase 9 — frontend-service

### Issue: container crash-loops, "executable file not found in $PATH"

**Symptom:** Pod crash-loops immediately on start with `exec: "server.js": executable file not found in $PATH`.

**Cause:** Dockerfile used `ENTRYPOINT ["server.js"]`. This **overrides** the distroless base image's existing `ENTRYPOINT ["/nodejs/bin/node"]` instead of combining with it — so the container tried to execute `server.js` directly as a binary, not run it with Node.

**Fix:** use `CMD ["server.js"]` instead of `ENTRYPOINT`. `CMD` combines with the base image's existing `ENTRYPOINT`, so the effective command becomes `node server.js`.

**Rule of thumb:** on a base image that already defines `ENTRYPOINT` (like distroless Node/Python images), use `CMD` for your app's arguments — only override `ENTRYPOINT` if you actually want to replace the base binary.

---

## Phase 4 — RDS: `terraform apply` fails recreating Secrets Manager secret

**Symptom:** `terraform apply` (or `down-poc.sh` → `up-poc.sh` cycle) fails with `InvalidRequestException: ... already scheduled for deletion`.

**Cause:** Secrets Manager defaults to a 30-day soft-delete window (`recovery_window_in_days`). For a POC/dev environment that gets torn down and rebuilt often, a deleted secret can't be recreated with the same name until that window lapses.

**Fix:** set `recovery_window_in_days = 0` on the secret resource — makes deletes immediate, so `down-poc.sh` → `up-poc.sh` cycles never collide on the secret name.

---

## Phase 11 — Prometheus PVC stuck `Pending`

**Symptom:** Prometheus server pod stuck `Pending`. `kubectl describe pod` shows `1 pod has unbound immediate PersistentVolumeClaims`.

**Cause:** the cluster's default `gp2` StorageClass (from the EKS default addon set) uses the deprecated **in-tree** `kubernetes.io/aws-ebs` provisioner, which no longer works on this cluster's Kubernetes version — so the PVC can never bind.

**Fix:** apply the EBS CSI driver module **before** Monitoring. It installs a `gp3` StorageClass on the current `ebs.csi.aws.com` provisioner, marked cluster-default — the PVC binds once that exists.

**Note:** Cluster Autoscaler correctly does *not* try to fix this by adding nodes — its logs show `NotTriggerScaleUp: pod didn't trigger scale-up: 1 pod has unbound immediate PersistentVolumeClaims`. It recognizes a storage problem isn't solved by adding compute. Don't waste time checking node capacity if you see this — go straight to checking the StorageClass/CSI driver.

---

## Phase 11 — destroy order: orphaned EBS volume / orphaned ALB

**Symptom:** after tearing down infra, an EBS volume (or an ALB) is still sitting in the AWS account, costing money, with nothing in Terraform state referencing it anymore.

**Cause:** some AWS resources are created **outside** Terraform's direct control, by a controller reacting to a Kubernetes resource — the AWS Load Balancer Controller creates a real ALB when an `Ingress` exists; the EBS CSI driver creates a real EBS volume when a `PersistentVolumeClaim` exists. If you destroy the Terraform module that runs the controller *before* deleting the Kubernetes resource that triggered creation, the controller is gone and can never clean up what it created.

**Fix — correct destroy order:**
- Delete `Ingress` resources (or the `monitoring` Helm release, which owns the Prometheus PVC) **before** destroying `alb-controller` / `ebs-csi`.
- Full order, enforced in `down-poc.sh`:
```
external-secrets -> monitoring -> cluster-autoscaler -> ebs-csi -> alb-controller -> ...
```

---

## Template for new entries

```
## Phase N — <component>

**Symptom:** what you saw (error message, pod state, etc.)

**Cause:** the actual root cause, not just the symptom

**Fix:** what you changed to resolve it
```