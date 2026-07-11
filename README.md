# platform-infrastructure

Central platform repo for the **Acme Cloud** microservices project — Terraform, CI/CD, and cluster config for all application services.

## Documentation — start here

We have 3 docs now, each answering a different question. Read in this order the first time:

| Doc | Answers | Read when |
|---|---|---|
| **This file (`README.md`)** | What is this project, what's the architecture, what phase are we on, how does everything connect | First, and any time you need the big picture |
| **[`Must-Manual-setup.md`](Must-Manual-setup.md)** | How do I set up my machine from zero? (AWS account, IAM user, CLI, Terraform install) | Once, before the very first `terraform init` |
| **[`RUNBOOK.md`](RUNBOOK.md)** | What exact command do I run right now, for deploy/verify/destroy? | Every session — this is your day-to-day cheat sheet |
| **[`POC.md`](POC.md)** | Why did we design it this way? (ALB vs nginx, no API Gateway, network layout, per-service breakdown) | When you need the reasoning behind a decision — e.g. for an interview |

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

Update the checkbox as each phase completes. This is our single source of truth for where the build stands. Full detail on what each completed phase built and how it connects lives right below this tracker.

- [✅] **Phase 1 — GitHub org + 4 repos created**
- [✅] **Phase 2 — VPC/networking Terraform** (VPC, public/private subnets, IGW, NAT Gateway)
- [✅] **Phase 3 — EKS cluster + managed node group**
- [✅] **Phase 4 — ECR repos + RDS (private subnet)**
- [✅] **Phase 5 — IAM OIDC provider for GitHub Actions (no static keys)**
- [✅] **Phase 6 — AWS Load Balancer Controller (Ingress → real ALB)** *(current)*
- [ ] **Phase 7 — External Secrets Operator + Secrets Manager wiring**
- [ ] **Phase 8 — `backend-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed**
- [ ] **Phase 9 — `frontend-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed**
- [ ] **Phase 10 — `notification-service`: Dockerfile, K8s manifests, CI/CD pipeline, deployed (zero infra changes)**
- [ ] **Phase 11 — Prometheus/Grafana + Cluster Autoscaler, verified under load**

---

## Architecture & connections — what each phase built, and how it connects

Diagrams use Mermaid — render natively on GitHub.

### Phase 1 — GitHub Org + Repos

**What exists:**
- Org: `acme-cloud-platform`
- Repos: `platform-infrastructure`, `frontend-service`, `backend-service`, `notification-service`

**Connection to later phases:** every repo will eventually hold a `.github/workflows/deploy.yml` that assumes the IAM role built in Phase 5. No AWS connection exists yet at this phase — purely source control.

```mermaid
graph LR
    ORG[GitHub Org: acme-cloud-platform]
    ORG --> R1[platform-infrastructure]
    ORG --> R2[frontend-service]
    ORG --> R3[backend-service]
    ORG --> R4[notification-service]
```

### Phase 2 — VPC / Networking

**What exists:**
| Resource | Value |
|---|---|
| VPC | `vpc-0d0f8e9094111d711` (`10.0.0.0/16`) |
| Public subnets | `10.0.0.0/24` (us-east-1a), `10.0.1.0/24` (us-east-1b) |
| Private subnets | `10.0.10.0/24` (us-east-1a), `10.0.11.0/24` (us-east-1b) |
| Internet Gateway | `acme-cloud-poc-igw` |
| NAT Gateway | `acme-cloud-poc-nat` (single NAT, in public subnet) |
| Route tables | `acme-cloud-poc-public-rt`, `acme-cloud-poc-private-rt` |

**How it connects:**
- Public subnets route `0.0.0.0/0` → **Internet Gateway** directly (inbound/outbound internet)
- Private subnets route `0.0.0.0/0` → **NAT Gateway** (outbound only — private subnet resources can reach the internet to pull images/updates, but nothing from the internet can initiate a connection to them)
- Public subnets are tagged `kubernetes.io/role/elb = 1` — tells the AWS Load Balancer Controller (Phase 6) "put internet-facing ALBs here"
- Private subnets are tagged `kubernetes.io/role/internal-elb = 1` — tells it "put internal ALBs here" and this is also where EKS nodes + RDS live

```mermaid
graph TB
    subgraph VPC["VPC 10.0.0.0/16"]
        subgraph PubA["Public Subnet 10.0.0.0/24 (1a)"]
        end
        subgraph PubB["Public Subnet 10.0.1.0/24 (1b)"]
        end
        subgraph PrivA["Private Subnet 10.0.10.0/24 (1a)"]
        end
        subgraph PrivB["Private Subnet 10.0.11.0/24 (1b)"]
        end
        IGW[Internet Gateway]
        NAT[NAT Gateway]
    end
    Internet((Internet)) <--> IGW
    IGW <--> PubA
    IGW <--> PubB
    PubA --- NAT
    NAT --> PrivA
    NAT --> PrivB
```

### Phase 3 — EKS Cluster + Node Group

**What exists:**
| Resource | Value |
|---|---|
| Cluster | `acme-cloud-poc-eks` |
| Cluster endpoint | `https://1CE30413C41DA517ADB1C61C126172E5.gr7.us-east-1.eks.amazonaws.com` |
| Cluster security group | `sg-02080e5747d7198f9` |
| Cluster IAM role | `acme-cloud-poc-eks-cluster-role` (trusts `eks.amazonaws.com`) |
| Node IAM role | `acme-cloud-poc-eks-node-role` — `arn:aws:iam::338449997393:role/acme-cloud-poc-eks-node-role` (trusts `ec2.amazonaws.com`) |
| Node group | `acme-cloud-poc-nodes` — 2× `t3.micro`, private subnets only |
| Auth mode | `API_AND_CONFIG_MAP` (needed for Phase 5's access entries) |

**How it connects:**
- Cluster control plane ENIs sit across **all 4 subnets** (public + private) from Phase 2
- Worker nodes (the actual EC2 instances) sit **only in private subnets** — no public IP, no direct internet exposure, all outbound traffic goes through the NAT Gateway
- `acme-cloud-poc-eks-node-role` has 3 AWS-managed policies attached: `AmazonEKSWorkerNodePolicy` (talk to control plane), `AmazonEC2ContainerRegistryReadOnly` (pull images from ECR — connects to Phase 4), `AmazonEKS_CNI_Policy` (pod networking)
- `acme-cloud-poc-eks-cluster-role` has `AmazonEKSClusterPolicy` attached — lets AWS manage the control plane on your behalf

```mermaid
graph TB
    subgraph AWS_IAM["IAM"]
        ClusterRole[acme-cloud-poc-eks-cluster-role]
        NodeRole[acme-cloud-poc-eks-node-role]
    end
    subgraph VPC["Private Subnets (from Phase 2)"]
        Node1[EC2 node 1 - t3.micro]
        Node2[EC2 node 2 - t3.micro]
    end
    ClusterRole -->|AmazonEKSClusterPolicy| CP[EKS Control Plane<br/>acme-cloud-poc-eks]
    NodeRole -->|WorkerNodePolicy + CNI + ECR ReadOnly| Node1
    NodeRole --> Node2
    Node1 -->|joins via kubelet| CP
    Node2 -->|joins via kubelet| CP
```

### Phase 4 — ECR Repos + RDS

**What exists — ECR:**
| Repo | URL |
|---|---|
| frontend | `338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-frontend` |
| backend | `338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-backend` |
| notification | `338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-notification` |

**What exists — RDS:**
| Resource | Value |
|---|---|
| DB instance | `acme-cloud-poc-db` (Postgres 16.4, `db.t3.micro`) |
| Endpoint | `acme-cloud-poc-db.c8vqsikioi3n.us-east-1.rds.amazonaws.com` |
| Subnet group | private subnets only (from Phase 2) |
| Security group | `sg-0cc373dbdf0493486` |
| Secrets Manager secret | `arn:aws:secretsmanager:us-east-1:338449997393:secret:acme-cloud-poc-rds-credentials-GLxxD4` |
| Publicly accessible | `false` |

**How it connects:**
- RDS security group `sg-0cc373dbdf0493486` allows inbound **only** from the **EKS cluster security group** (`sg-02080e5747d7198f9`, from Phase 3) on port 5432 — nothing else in the account, and nothing on the internet, can reach the database
- DB credentials (username, password, host, port) are stored as JSON in Secrets Manager — this secret ARN is what **External Secrets Operator** (Phase 7, not built yet) will sync into a Kubernetes Secret
- ECR repos have zero network dependency — they're pulled into the picture only when the node IAM role (`acme-cloud-poc-eks-node-role`, Phase 3) uses its `AmazonEC2ContainerRegistryReadOnly` permission to pull images at pod-start time

```mermaid
graph TB
    subgraph ECR["Amazon ECR"]
        E1[frontend repo]
        E2[backend repo]
        E3[notification repo]
    end
    subgraph SG["Security Groups"]
        EksSg[EKS cluster SG<br/>sg-02080e57...]
        RdsSg[RDS SG<br/>sg-0cc373db...]
    end
    subgraph RDS["Private Subnet"]
        DB[(acme-cloud-poc-db<br/>Postgres 16.4)]
    end
    SM[Secrets Manager<br/>acme-cloud-poc-rds-credentials]

    NodeRole[eks-node-role] -->|pulls images| ECR
    EksSg -->|allowed inbound 5432 only| RdsSg
    RdsSg --> DB
    DB -.credentials stored in.-> SM
```

### Phase 5 — IAM OIDC Provider for GitHub Actions

**What exists:**
| Resource | Value |
|---|---|
| OIDC provider | `arn:aws:iam::338449997393:oidc-provider/token.actions.githubusercontent.com` |
| Deploy role | `acme-cloud-poc-github-deploy-role` — `arn:aws:iam::338449997393:role/acme-cloud-poc-github-deploy-role` |
| Trusted repos | `frontend-service`, `backend-service`, `notification-service`, `platform-infrastructure` (org: `acme-cloud-platform`) |
| EKS access entry | maps the deploy role to `AmazonEKSEditPolicy` (cluster-scoped) |

**How it connects — the full trust chain:**

1. A GitHub Actions workflow runs in, say, `backend-service`
2. GitHub mints a short-lived OIDC token, signed, claiming `repo:acme-cloud-platform/backend-service:*`
3. The workflow calls AWS STS `AssumeRoleWithWebIdentity`, presenting that token
4. AWS checks: does this token's issuer match `oidc-provider/token.actions.githubusercontent.com`? ✅ (the OIDC provider resource)
5. AWS checks: does the `sub` claim in the token match one of the `StringLike` conditions on `acme-cloud-poc-github-deploy-role`'s trust policy? ✅ (repo is in the allowed list)
6. AWS issues **temporary credentials**, scoped to this role, valid only for the workflow run's duration — no static key was ever stored anywhere
7. Those temporary credentials carry two attached inline policies: `ecr-push` (can push images to any of the 3 ECR repos from Phase 4) and `eks-describe` (can call `DescribeCluster`, needed for `aws eks update-kubeconfig`)
8. Separately, the **EKS Access Entry** maps this same role ARN to `AmazonEKSEditPolicy` inside the cluster's own RBAC — this is what actually lets `kubectl apply` succeed once authenticated, since IAM permissions alone don't grant Kubernetes-level permissions

```mermaid
sequenceDiagram
    participant GH as GitHub Actions<br/>(backend-service)
    participant OIDC as GitHub OIDC token issuer
    participant STS as AWS STS
    participant Role as github-deploy-role
    participant ECR as Amazon ECR
    participant EKS as EKS Cluster RBAC

    GH->>OIDC: request short-lived token
    OIDC-->>GH: signed token (sub=repo:org/backend-service:*)
    GH->>STS: AssumeRoleWithWebIdentity(token)
    STS->>Role: check trust policy (issuer + sub match?)
    Role-->>STS: ✅ trusted
    STS-->>GH: temporary AWS credentials
    GH->>ECR: push image (ecr-push policy)
    GH->>EKS: kubectl apply (via EKS Access Entry → EditPolicy)
```

### Phase 6 — AWS Load Balancer Controller

**What exists:**
| Resource | Value |
|---|---|
| EKS OIDC provider (IRSA) | `arn:aws:iam::338449997393:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/1CE30413C41DA517ADB1C61C126172E5` |
| Controller IAM role | `acme-cloud-poc-alb-controller-role` — `arn:aws:iam::338449997393:role/acme-cloud-poc-alb-controller-role` |
| Controller IAM policy | official AWS-published policy — full ELB/EC2 permissions to create/manage ALBs, target groups, listeners, security groups |
| Kubernetes ServiceAccount | `aws-load-balancer-controller` in `kube-system`, annotated with the IAM role ARN |
| Helm release | `aws-load-balancer-controller` chart v1.8.1, 2 replicas, both `Running` |

**How it connects — a different kind of OIDC than Phase 5:**

Phase 5's OIDC lets something **outside** AWS (GitHub Actions) assume a role. Phase 6 uses a different mechanism called **IRSA** (IAM Roles for Service Accounts) — it lets a **pod running inside EKS** assume a role, using the cluster's own built-in OIDC issuer (`oidc.eks.us-east-1.amazonaws.com/id/...`), which is separate from GitHub's OIDC issuer.

The trust is entirely carried by one annotation on the Kubernetes ServiceAccount:
```
eks.amazonaws.com/role-arn: arn:aws:iam::338449997393:role/acme-cloud-poc-alb-controller-role
```
When the controller pod starts using that ServiceAccount, EKS automatically injects temporary AWS credentials scoped to that role — no secret, no key, ever stored in the cluster.

Once running, the controller watches the Kubernetes API for `Ingress` resources. When `backend-service`/`frontend-service` (Phase 8/9) create one, the controller reads the subnet tags from Phase 2 (`kubernetes.io/role/elb` for public, `kubernetes.io/role/internal-elb` for private) to decide where to place the ALB, then calls the AWS ELB API directly using its IRSA credentials to actually create it.

```mermaid
graph TB
    subgraph EKS["EKS Cluster"]
        SA[ServiceAccount<br/>aws-load-balancer-controller]
        Pod1[Controller pod 1]
        Pod2[Controller pod 2]
        Ing[Ingress resource<br/>created later in Phase 8/9]
    end
    OIDC[EKS OIDC Provider<br/>cluster's own issuer]
    Role[alb-controller-role]
    Policy[Official AWS ELB/EC2 policy]

    SA -.annotated with role ARN.-> Role
    OIDC --> Role
    Role --> Policy
    Pod1 -->|uses| SA
    Pod2 -->|uses| SA
    Ing -->|watched by| Pod1
    Pod1 -->|creates via IRSA creds| ALB[Real ALB in AWS]
    ALB -->|placed using subnet tags| Pub[Public subnets, Phase 2]
```



### Full picture so far — everything connected (Phases 1-6)

```mermaid
graph TB
    subgraph GitHub["Phase 1 — GitHub"]
        Repos[4 repos in acme-cloud-platform org]
    end

    subgraph OIDC5["Phase 5 — GitHub Trust"]
        Provider[GitHub OIDC Provider]
        DeployRole[github-deploy-role]
    end

    subgraph Network["Phase 2 — VPC"]
        Pub[Public subnets: ALB, NAT]
        Priv[Private subnets: EKS nodes, RDS]
    end

    subgraph Compute["Phase 3 — EKS"]
        Cluster[EKS Cluster]
        Nodes[Worker Nodes]
        NodeRole[node-role]
    end

    subgraph Data["Phase 4 — Data"]
        ECRRepos[3 ECR repos]
        RDS[(RDS Postgres)]
        Secret[Secrets Manager]
    end

    subgraph OIDC6["Phase 6 — Cluster Trust (IRSA)"]
        EksOidc[EKS OIDC Provider]
        AlbRole[alb-controller-role]
        AlbPods[Controller pods x2]
    end

    Repos -->|OIDC token| Provider
    Provider --> DeployRole
    DeployRole -->|push images| ECRRepos
    DeployRole -->|kubectl apply, via Access Entry| Cluster
    NodeRole -->|pull images| ECRRepos
    Nodes -->|query, SG-restricted| RDS
    RDS -.creds.-> Secret
    Cluster --> Nodes
    Nodes -.-> Priv
    Cluster -.control plane ENIs.-> Pub
    Cluster -.-> Priv
    EksOidc --> AlbRole
    AlbRole --> AlbPods
    AlbPods -->|runs on| Nodes
    AlbPods -->|will create ALB in| Pub
```

### Quick-reference: every ARN / ID we have so far

```
VPC ID:                    vpc-0d0f8e9094111d711
EKS cluster:                acme-cloud-poc-eks
EKS cluster SG:              sg-02080e5747d7198f9
EKS node role:                arn:aws:iam::338449997393:role/acme-cloud-poc-eks-node-role
RDS endpoint:                  acme-cloud-poc-db.c8vqsikioi3n.us-east-1.rds.amazonaws.com
RDS security group:              sg-0cc373dbdf0493486
RDS secret:                        arn:aws:secretsmanager:us-east-1:338449997393:secret:acme-cloud-poc-rds-credentials-GLxxD4
GitHub OIDC provider:                arn:aws:iam::338449997393:oidc-provider/token.actions.githubusercontent.com
GitHub deploy role:                    arn:aws:iam::338449997393:role/acme-cloud-poc-github-deploy-role
EKS OIDC provider (IRSA):                arn:aws:iam::338449997393:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/1CE30413C41DA517ADB1C61C126172E5
ALB controller role:                       arn:aws:iam::338449997393:role/acme-cloud-poc-alb-controller-role
ECR frontend:      338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-frontend
ECR backend:        338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-backend
ECR notification:     338449997393.dkr.ecr.us-east-1.amazonaws.com/acme-cloud-poc-notification
```

*(Phases 7-11 will be appended here, in this same section, as we build them.)*

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
├── POC.md
├── RUNBOOK.md
├── Must-Manual-setup.md
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