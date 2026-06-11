# DevOps Project

A production-style cloud infrastructure project demonstrating end-to-end DevOps practices — infrastructure as code, containerization, Kubernetes orchestration, and automated CI/CD.

---

## Architecture

```
                    Internet
                       │
          ┌────────────┴────────────┐
          │                         │
   AWS Load Balancer          AWS Load Balancer
          │                         │
    React App (EKS)           pgAdmin (EKS)
                                    │
                            RDS PostgreSQL
                          (private subnets)
```

All resources run inside a custom AWS VPC with public and private subnets across two availability zones.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Cloud Provider | AWS (eu-west-1) |
| Infrastructure as Code | Terraform |
| Container Registry | Amazon ECR |
| Container Orchestration | Amazon EKS (Kubernetes 1.30) |
| Database | Amazon RDS PostgreSQL 15 |
| Frontend | React 19 (served by Nginx) |
| DB Management UI | pgAdmin 4 |
| CI/CD | GitHub Actions |
| Containerization | Docker |

---

## Project Structure

```
devops-project/
├── terraform/
│   ├── main.tf          # All AWS resources
│   ├── backend.tf       # S3 remote state configuration
│   ├── variables.tf     # Input variables
│   ├── outputs.tf       # EKS endpoint, ECR URL, RDS endpoint
│   └── providers.tf     # AWS provider config
│
├── app/
│   ├── src/             # React source code
│   ├── Dockerfile       # Multi-stage build (Node → Nginx)
│   └── package.json
│
├── kubernetes/
│   ├── namespace.yaml       # devops-app namespace
│   ├── configmap.yaml       # Non-sensitive app config
│   ├── deployment.yaml      # React app deployment (2 replicas)
│   ├── service.yaml         # React app LoadBalancer service
│   ├── aws-auth.yaml        # EKS cluster access config
│   └── pgadmin/
│       ├── deployment.yaml  # pgAdmin deployment
│       └── service.yaml     # pgAdmin LoadBalancer service
│
└── .github/
    └── workflows/
        └── deploy.yml   # CI/CD pipeline
```

---

## Infrastructure (Terraform)

> **Docs:** [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) · [EKS with Terraform](https://developer.hashicorp.com/terraform/tutorials/kubernetes/eks) · [RDS Terraform Resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance)

The following AWS resources are provisioned by Terraform:

- **VPC** — `10.0.0.0/16` with 2 public and 2 private subnets across 2 AZs
- **Internet Gateway** + public route table
- **ECR Repository** — private Docker image registry with scan on push
- **RDS PostgreSQL** — `db.t3.micro`, 20GB, deployed in private subnets
- **EKS Cluster** — Kubernetes 1.30, managed node group (2x `t3.small`, scales 1-3)
- **IAM Roles** — EKS cluster role, node role, CI/CD user with required permissions
- **Security Groups** — EKS (port 443), RDS (port 5432 from EKS only)

### Remote State (S3)

> **Docs:** [Terraform S3 Backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)

Terraform state is stored remotely in an S3 bucket rather than locally. This prevents state loss, enables team collaboration, and is the standard approach for any production Terraform setup.

The S3 bucket was created manually via AWS CLI before initialising Terraform, with versioning and server-side encryption enabled:

```bash
aws s3api create-bucket \
  --bucket my-devops-project-010 \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket my-devops-project-010 \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket my-devops-project-010 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

`backend.tf` configures Terraform to use this bucket:

```hcl
terraform {
  backend "s3" {
    bucket  = "my-devops-project-010"
    key     = "q1-devops-project/terraform.tfstate"
    region  = "eu-west-1"
    encrypt = true
  }
}
```

State was migrated from local to S3 with:

```bash
terraform init -migrate-state
```

### Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan -var="db_password=YOUR_PASSWORD"
terraform apply -var="db_password=YOUR_PASSWORD"
```

---

## Applications

### React App

> **Docs:** [Docker multi-stage builds](https://docs.docker.com/build/building/multi-stage/) · [Nginx Docker image](https://hub.docker.com/_/nginx)

Default Create React App served via Nginx. Containerized with a multi-stage Dockerfile — Node builds the static files, Nginx serves them. The multi-stage approach keeps the final image small by discarding the Node build environment.

### pgAdmin

> **Docs:** [pgAdmin Docker image](https://hub.docker.com/r/dpage/pgadmin4)

Ready-made database administration UI (`dpage/pgadmin4`). Deployed to EKS and connected to the RDS instance via Kubernetes Secrets. Accessible via a public Load Balancer URL.

---

## CI/CD Pipeline

> **Docs:** [GitHub Actions workflow syntax](https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions) · [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials) · [aws-actions/amazon-ecr-login](https://github.com/aws-actions/amazon-ecr-login)

The GitHub Actions pipeline (`.github/workflows/deploy.yml`) triggers on every push to `main` and:

1. Authenticates to AWS using IAM credentials stored as GitHub Secrets
2. Logs in to ECR
3. Builds the React Docker image and pushes it to ECR
4. Connects `kubectl` to the EKS cluster
5. Updates the EKS `aws-auth` ConfigMap
6. Creates/updates the Kubernetes Secret from GitHub Secrets
7. Applies all Kubernetes manifests
8. Rolls out the new React image

---

## Secrets Management

> **Docs:** [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) · [GitHub encrypted secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)

Sensitive values are never stored in the repository.

| Where | What |
|---|---|
| `.gitignore` | `kubernetes/secret.yaml` excluded from git |
| GitHub Secrets | AWS credentials, DB password, pgAdmin credentials |
| Kubernetes Secret | Injected at runtime by the CI/CD pipeline |

---

## Setup

### Prerequisites
- AWS CLI configured
- Terraform >= 1.0
- kubectl
- Docker

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID |
| `AWS_REGION` | AWS region (e.g. eu-west-1) |
| `DB_PASSWORD` | RDS database password |
| `DB_HOST` | RDS endpoint |
| `PGADMIN_EMAIL` | pgAdmin login email |
| `PGADMIN_PASSWORD` | pgAdmin login password |

### Manual deployment steps

```bash
# 1. Provision infrastructure
cd terraform && terraform apply

# 2. Build and push React image
cd app
docker build -t ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/devops-project-repo:react-latest .
docker push ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/devops-project-repo:react-latest

# 3. Connect to EKS
aws eks update-kubeconfig --region eu-west-1 --name dp-cluster

# 4. Apply Kubernetes manifests
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/aws-auth.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/pgadmin/deployment.yaml
kubectl apply -f kubernetes/pgadmin/service.yaml

# 5. Check everything is running
kubectl get pods -n devops-app
kubectl get services -n devops-app
```

---

## Kubernetes

> **Docs:** [Kubernetes concepts](https://kubernetes.io/docs/concepts/) · [kubectl reference](https://kubernetes.io/docs/reference/kubectl/) · [EKS user guide](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html) · [aws-auth ConfigMap](https://docs.aws.amazon.com/eks/latest/userguide/auth-configmap.html)

---

## Key DevOps Concepts Demonstrated

- **Infrastructure as Code** — all AWS resources defined and versioned in Terraform
- **Immutable infrastructure** — apps run as Docker containers, never patched in place
- **GitOps** — pushing to `main` automatically triggers deployment
- **Secrets management** — no credentials in source code or committed files
- **Remote state** — Terraform state stored in S3 with versioning and encryption
- **High availability** — React app runs 2 replicas across 2 availability zones
- **Network security** — RDS in private subnets, only accessible from within the VPC
- **Least privilege** — CI/CD user has only the permissions it needs
