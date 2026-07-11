# Proof of Concept — Enterprise Microservices Platform

## 1. Objective

Demonstrate an enterprise-grade DevOps/Platform Engineering setup:
- **Application teams** own independent microservice repos with their own CI/CD.
- **Platform team** (you) owns one infrastructure repo that provisions AWS/EKS once, and never changes when new services are added.
- Everything is production-shaped: private DB, OIDC auth (no static AWS keys), managed secrets, autoscaling, observability.

---

## 2. Repositories

| Repo | Owner | Contains |
|---|---|---|
| `frontend-service` | App team | React app, Dockerfile, K8s/Helm values, workflow |
| `backend-service` | App team | FastAPI app, Dockerfile, K8s/Helm values, workflow |
| `notification-service` | App team | Worker app, Dockerfile, K8s/Helm values, workflow |
| `platform-infrastructure` | Platform team (you) | Terraform, Helm charts, reusable workflow, K8s base manifests |

No application code ever lives in `platform-infrastructure`. No infra code ever lives in a service repo.

---

## 3. Microservices — detailed responsibilities

### 3.1 frontend-service
- **Stack**: React (or plain HTML/JS for POC simplicity)
- **Responsibility**: Serve the UI, call `backend-service` over internal cluster networking (or via the ALB path `/api`)
- **Exposed via**: Ingress path `/` → frontend Service → frontend Pods
- **Docker**: multi-stage build (build React → serve via nginx or a lightweight static server) — this nginx is just a static file server inside the container, unrelated to cluster ingress
- **Scaling**: HPA on CPU, 2–5 replicas

### 3.2 backend-service
- **Stack**: FastAPI (Python)
- **Responsibility**: `/order` endpoint — accepts an order, writes to RDS, publishes an event (simple case: writes a row that notification-service polls, or calls it directly via internal HTTP)
- **Exposed via**: Ingress path `/api` → backend Service → backend Pods
- **Connects to**: Amazon RDS (private subnet), via credentials synced from Secrets Manager by External Secrets Operator
- **Docker**: single-stage, `uvicorn` entrypoint
- **Scaling**: HPA on CPU, 2–10 replicas (this is the one that spikes under load)

### 3.3 notification-service
- **Stack**: simple Python/Node worker
- **Responsibility**: reacts to new orders (poll DB table or receive internal HTTP call from backend), logs "email sent" — no real SMTP needed for POC
- **Exposed via**: nothing external — internal only, no Ingress rule
- **Purpose in the POC**: proves that adding a 3rd service required **zero changes to platform-infrastructure** — just a new repo, Dockerfile, and workflow call

### 3.4 What each service repo actually contains
```
<service>/
├── src/ (or app/)
├── Dockerfile
├── .github/workflows/deploy.yml   ← ~10 lines, calls the reusable workflow
├── helm-values.yaml                ← image tag placeholder, replicas, env vars
└── README.md
```

---

## 4. Network architecture (locked)

- **VPC** — single VPC, multi-AZ
- **Public subnets** (2, one per AZ): ALB, NAT Gateway
- **Private subnets** (2, one per AZ): EKS worker nodes, RDS
- **Internet Gateway**: attached to VPC, routes public subnet traffic
- **NAT Gateway**: sits in public subnet; lets private-subnet resources (EKS nodes) reach the internet outbound (pull images, OS updates) without being reachable from the internet
- **RDS**: private subnet only, no public IP, security group allows inbound only from the EKS node security group on port 5432

## 5. Ingress / edge (locked)

- **No nginx ingress controller.**
- **AWS Load Balancer Controller** runs as a pod inside EKS, watches Kubernetes `Ingress` resources, and provisions/configures a real ALB automatically.
- Routing rules (`/` → frontend, `/api` → backend) live in the `Ingress` YAML.
- ALB handles TLS termination via an ACM certificate.
- **No API Gateway** — not needed since there's no external API product, only a browser-facing app.

## 6. Secrets (locked)

- **AWS Secrets Manager** stores RDS credentials.
- **External Secrets Operator (ESO)** — a pod in EKS — syncs those secrets into native Kubernetes `Secret` objects automatically.
- Applications read a K8s Secret; nothing is hardcoded, nothing is committed to Git.
- Rotation in Secrets Manager doesn't require redeploying app code.

## 7. CI/CD authentication (locked)

- **No static AWS access keys stored in GitHub, anywhere.**
- **IAM OIDC provider** trusts GitHub Actions' OIDC token issuer.
- An IAM role is scoped to trust only specific repos/branches in your GitHub org.
- Each workflow run requests a short-lived token via OIDC, assumes the IAM role, gets temporary credentials, does its job, credentials expire.

## 8. CI/CD workflow (per service, identical pattern)

```
git push (service repo)
    ↓
GitHub Actions triggers
    ↓
calls platform-infrastructure's reusable workflow
    ↓
OIDC → assume IAM role (no stored keys)
    ↓
Docker build (tag = commit SHA)
    ↓
push image → Amazon ECR (service's own repo)
    ↓
helm upgrade / kubectl apply → updates only that service's Deployment in EKS
```

Reusable workflow lives at:
`platform-infrastructure/.github/workflows/reusable-deploy.yml`

Each service repo's own workflow is just:
```yaml
jobs:
  deploy:
    uses: your-org/platform-infrastructure/.github/workflows/reusable-deploy.yml@main
    with:
      service-name: backend-service
      ecr-repo: backend
```

## 9. Observability

- **CloudWatch** — infra-level logs/metrics (EKS control plane, RDS, ALB)
- **Prometheus + Grafana** — in-cluster app/pod-level metrics, deployed via Terraform-managed Helm release
- **Cluster Autoscaler** — scales EC2 node count based on pending pods
- **HPA** (per service) — scales pod count based on CPU/memory

## 10. Terraform scope (what `platform-infrastructure/terraform` provisions)

1. VPC, public/private subnets, IGW, NAT Gateway, route tables
2. EKS cluster + managed node group (private subnets)
3. 3x ECR repositories
4. RDS Postgres (private subnet)
5. IAM OIDC provider + role for GitHub Actions
6. AWS Load Balancer Controller (Helm release via Terraform)
7. External Secrets Operator (Helm release via Terraform)
8. Secrets Manager secret for RDS credentials
9. Prometheus + Grafana (Helm release via Terraform)
10. Cluster Autoscaler (Helm release via Terraform)

## 11. Build order

| Phase | What gets built | Testable outcome |
|---|---|---|
| 1 | VPC + subnets + NAT + IGW | `terraform plan/apply` succeeds, subnets visible in AWS console |
| 2 | EKS + node group | `kubectl get nodes` shows healthy nodes |
| 3 | ECR + RDS | Can push a test image; can connect to RDS from a bastion/pod |
| 4 | IAM OIDC provider | GitHub Actions can assume role, no static keys |
| 5 | AWS Load Balancer Controller | Test Ingress resource provisions a real ALB |
| 6 | External Secrets Operator + Secrets Manager | K8s Secret auto-populates from Secrets Manager |
| 7 | `backend-service` repo | Deploys via its own pipeline, reachable via `/api`, writes to RDS |
| 8 | `frontend-service` repo | Deploys via its own pipeline, reachable via `/`, calls backend |
| 9 | `notification-service` repo | Deploys via its own pipeline — **zero infra changes needed** |
| 10 | Prometheus/Grafana + Cluster Autoscaler | Dashboards show live pod metrics, autoscaling verified under load |

---

## 12. Three perspectives (for portfolio narrative)

**Developer side**: touches only their service repo — code, Dockerfile, Helm values. Push → pipeline → pod updates. Never touches Terraform or AWS console.

**DevOps side**: owns Terraform state and the one reusable workflow. Adding a new microservice costs a new repo + a values file — zero infra changes.

**Client/user side**: hits a public HTTPS URL → ALB → correct pod → response. Sees uptime and correctness only, nothing about pipelines or clusters.
