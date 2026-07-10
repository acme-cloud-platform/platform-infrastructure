# platform-infrastructure

Central platform repo for the **Acme Cloud** microservices project — Terraform, CI/CD, and cluster config for all application services.

> Full POC document with detailed architecture: see `POC-platform-engineering-project.md` (also kept in this repo).

---

## Organization repos

| Repo | Purpose | Status |
|---|---|---|
| [`platform-infrastructure`](.) | Terraform, Helm, reusable CI/CD workflow | 🚧 in progress |
| `frontend-service` | React app | ⬜ not started |
| `backend-service` | FastAPI app | ⬜ not started |
| `notification-service` | Worker service | ⬜ not started |

---

## Architecture at a glance

**Network**: VPC → 2 public subnets (ALB, NAT Gateway) + 2 private subnets (EKS nodes, RDS)
**Ingress**: AWS Load Balancer Controller provisions ALB directly from K8s Ingress resources — no nginx
**Compute**: EKS + managed node group, autoscaled
**Database**: RDS Postgres, private subnet only, no public access
**Secrets**: Secrets Manager + External Secrets Operator → K8s Secrets
**CI/CD auth**: GitHub OIDC → IAM role, zero static AWS keys anywhere
**Registry**: 3 ECR repos (frontend, backend, notification)
**Observability**: CloudWatch + Prometheus/Grafana
**No API Gateway** — no external API product, ALB is sufficient

Each service repo owns: source code, Dockerfile, Helm values, and a workflow file that calls this repo's reusable workflow. This repo owns: Terraform, base Helm charts, the reusable workflow. Adding a new microservice never requires changing this repo.

---

## Phase tracker

Update the checkbox as each phase completes. This is our single source of truth for where the build stands.

- [ ] **Phase 1 — GitHub org + 4 repos created** *(current)*
- [ ] **Phase 2 — VPC/networking Terraform** (VPC, public/private subnets, IGW, NAT Gateway)
- [ ] **Phase 3 — EKS cluster + managed node group**
- [ ] **Phase 4 — ECR repos + RDS (private subnet)**
- [ ] **Phase 5 — IAM OIDC provider for GitHub Actions (no static keys)**
- [ ] **Phase 6 — AWS Load Balancer Controller (Ingress → real ALB)**
- [ ] **Phase 7 — External Secrets Operator + Secrets Manager wiring**
- [ ] **Phase 8 — `backend-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed**
- [ ] **Phase 9 — `frontend-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed**
- [ ] **Phase 10 — `notification-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed (zero infra changes)**
- [ ] **Phase 11 — Prometheus/Grafana + Cluster Autoscaler, verified under load**

---

## Repo structure (this repo)

```
platform-infrastructure/
├── terraform/
│   ├── vpc/
│   ├── eks/
│   ├── rds/
│   ├── ecr/
│   ├── iam-oidc/
│   ├── alb-controller/
│   ├── external-secrets/
│   └── monitoring/
├── helm/
│   └── (base charts / shared values)
├── kubernetes/
│   └── (cluster-level configs, namespaces, RBAC)
├── .github/workflows/
│   └── reusable-deploy.yml
├── POC-platform-engineering-project.md
└── README.md
```

## Repo structure (each service repo — same pattern)

```
<service>-service/
├── src/ (or app/)
├── Dockerfile
├── helm-values.yaml
├── .github/workflows/deploy.yml   ← calls platform-infrastructure's reusable workflow
└── README.md
```
