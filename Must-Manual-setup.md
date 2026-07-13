# Manual setup — do this ONCE before any Terraform runs

This file is our single place for every manual, one-time step. Nothing here
is automated on purpose — this is the human setup that has to happen before
any pipeline or Terraform apply can run. Check things off as you go.

---

## 1. Create an AWS account

1. Go to https://aws.amazon.com/ → **Create an AWS Account**
2. You'll need an email, a credit card (AWS requires it even for free-tier usage), and phone verification
3. Once in, go to the **Billing console** → set up a **Budget alert** (e.g. $10/month) so you get emailed if costs creep up — NAT Gateway, EKS, and RDS are the pieces that actually cost money in this project, so this matters
4. Note your **AWS Account ID** (top-right corner, click your account name) — you'll need this later

---

## 2. Create an IAM user (never use the root account for daily work)

The root account (the email/password you signed up with) should never be used for CLI/Terraform — it has unlimited power and no guardrails.

1. AWS Console → search **IAM** → Users → **Create user**
2. Username: `example-admin` (or your name)
3. Attach policy: `AdministratorAccess` (fine for a personal POC account; in a real company you'd scope this down)
4. After creating the user, go to that user → **Security credentials** tab → **Create access key**
5. Choose use case: **Command Line Interface (CLI)**
6. Save the **Access Key ID** and **Secret Access Key** somewhere safe (password manager) — AWS shows the secret only once

---

## 3. Install AWS CLI (macOS)

```bash
brew install awscli
aws --version
```
Should print something like `aws-cli/2.x.x`.

## 4. Connect AWS CLI to your account

```bash
aws configure
```
It will ask for 4 things:
```
AWS Access Key ID: <paste from step 2>
AWS Secret Access Key: <paste from step 2>
Default region name: us-east-1
Default output format: json
```

Verify it worked:
```bash
aws sts get-caller-identity
```
This should print your Account ID, User ID, and ARN — if you see that, your CLI is correctly talking to your AWS account.

---

## 5. Install Terraform, Terragrunt (macOS)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version
brew install terragrunt
terragrunt --version
```

That's it — everything else below is automated.

---

Should print something like `Terraform v1.7.x` or higher, `Terragrunt v1.1.x` or higher

---

## 6. Bootstrap the Terraform remote state backend

Terraform can't create the S3 bucket it will store its own state in — that's a chicken-and-egg problem, so this one step is manual, using the AWS CLI you just configured.

```bash
# 1. Create the S3 bucket for state (name must be globally unique — change if taken)
aws s3api create-bucket \
  --bucket acme-cloud-tfstate \
  --region us-east-1

# 2. Enable versioning (lets you recover previous state if something goes wrong)
aws s3api put-bucket-versioning \
  --bucket acme-cloud-tfstate \
  --versioning-configuration Status=Enabled

# 3. Enable encryption at rest
aws s3api put-bucket-encryption \
  --bucket acme-cloud-tfstate \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 4. Block all public access (state can contain resource IDs — never expose this bucket)
aws s3api put-public-access-block \
  --bucket acme-cloud-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 5. Create the DynamoDB table for state locking (prevents two people/pipelines
#    running terraform apply at the same time and corrupting state)
aws dynamodb create-table \
  --table-name acme-cloud-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

**Why this matters**: without a remote backend, Terraform state lives as a
local `.tfstate` file — which we gitignore because it can contain sensitive
resource data, and because local-only state means only your machine "knows"
what's deployed. With S3 + DynamoDB, state is shared, locked against
concurrent changes, versioned, and never touches Git.


---

## Checklist

- [✅] AWS account created + budget alert set
- [✅] IAM user created (not using root)
- [✅] AWS CLI installed
- [✅] `aws configure` done, `aws sts get-caller-identity` works
- [✅] Terraform, Terragrunt installed
- [✅] S3 bucket + DynamoDB table created (backend bootstrap)
