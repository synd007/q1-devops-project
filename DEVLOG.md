# DevOps Project — Build Log

A full record of everything done, every error encountered, and how each was debugged and resolved.

---

## Project Goal

Deploy a React frontend app and pgAdmin (database management UI) to AWS EKS, backed by a PostgreSQL RDS database, with a fully automated CI/CD pipeline using GitHub Actions.

---

## Architecture

```
Browser
  ├── React App  (EKS pod → AWS Load Balancer)
  └── pgAdmin    (EKS pod → AWS Load Balancer)
                        ↓
                 RDS PostgreSQL (private subnets)
                        ↑
              Kubernetes Secret (credentials)
                        ↑
              GitHub Actions (CI/CD pipeline)
                        ↑
                  ECR (Docker image registry)
```

---

## Phase 1 — Infrastructure (Terraform)

### What was already in place
- `terraform/main.tf` — provisioned:
  - VPC (`10.0.0.0/16`) with 2 public and 2 private subnets across 2 AZs
  - Internet Gateway + public route table
  - ECR repository (`devops-project-repo`)
  - RDS PostgreSQL 15 (`db.t3.micro`, 20GB, private subnets)
  - EKS cluster (`dp-cluster`, v1.29) with managed node group (2x `t3.small`)
  - IAM roles for EKS cluster and nodes
  - Security groups: `eks-sg` (port 443) and `rds-sg` (port 5432 from eks-sg)
- `terraform/variables.tf` — region, db username/password
- `terraform/outputs.tf` — EKS endpoint, ECR URL, RDS endpoint
- `terraform/providers.tf` — AWS provider ~> 6.0, region eu-west-1

### Issue 1 — EKS version drift
**Error:** `terraform plan` showed `version = "1.30" -> "1.29"` (attempted downgrade)  
**Cause:** AWS had auto-upgraded the cluster to 1.30 but `main.tf` still said 1.29  
**Fix:** Updated `main.tf` EKS cluster version from `"1.29"` to `"1.30"`

### Issue 2 — RDS unreachable from pgAdmin
**Error:** Connection timeout when pgAdmin tried to connect to RDS  
**Cause:** The RDS security group only allowed traffic from `eks-sg` (the manually created one). But EKS pods actually run under the auto-generated cluster security group, not `eks-sg`  
**Diagnosis:**
```bash
# Got EKS cluster security group
aws eks describe-cluster --name dp-cluster --region eu-west-1 \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
# Result: sg-0d771ad4125f7d789

# Checked RDS security group rules
aws ec2 describe-security-groups --region eu-west-1 \
  --group-ids sg-0ab5bfe63829aeee2 \
  --query 'SecurityGroups[0].IpPermissions' --output table
# Result: only allowed traffic from itself, not from EKS
```
**Manual fix:**
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0ab5bfe63829aeee2 \
  --protocol tcp \
  --port 5432 \
  --source-group sg-0d771ad4125f7d789 \
  --region eu-west-1
```
**Permanent fix in Terraform** — added second ingress rule to `rds-sg`:
```hcl
ingress {
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
}
```

### Issue 3 — Terraform tried to create existing IAM user
**Error:** `EntityAlreadyExists: User with name terraform-user already exists`  
**Cause:** `terraform-user` existed in AWS but not in Terraform state  
**Fix:**
```bash
terraform import aws_iam_user.cicd terraform-user
terraform apply
```

---

## Phase 2 — Docker & ECR

### React app Dockerfile (already existed)
```dockerfile
FROM node:alpine AS build
WORKDIR /app
COPY package*.json .
RUN npm install
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```
Multi-stage build: Node compiles React → Nginx serves static files.

### Building and pushing to ECR
```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com

# Build
cd ~/devops-project/app
docker build -t devops-project-react .

# Tag
docker tag devops-project-react:latest \
  ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/devops-project-repo:react-latest

# Push
docker push \
  ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/devops-project-repo:react-latest
```

---

## Phase 3 — Kubernetes Manifests

### Files created

**`kubernetes/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: devops-app
```

**`kubernetes/configmap.yaml`** — non-sensitive config
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: devops-app-config
  namespace: devops-app
data:
  REACT_APP_ENV: "production"
```

**`kubernetes/secret.yaml`** — kept out of git (added to .gitignore)  
Contains DB credentials and pgAdmin credentials. In CI/CD, secrets are injected from GitHub Secrets.

**`kubernetes/deployment.yaml`** — React app deployment + service  
**`kubernetes/service.yaml`** — React app LoadBalancer service  
**`kubernetes/pgadmin/deployment.yaml`** — pgAdmin deployment using `dpage/pgadmin4:latest`  
**`kubernetes/pgadmin/service.yaml`** — pgAdmin LoadBalancer service  
**`kubernetes/aws-auth.yaml`** — EKS cluster access for terraform-user

### Applying manifests
```bash
# Connect kubectl to EKS
aws eks update-kubeconfig --region eu-west-1 --name dp-cluster

# Apply in order (namespace first)
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/pgadmin/deployment.yaml
kubectl apply -f kubernetes/pgadmin/service.yaml
```

### Verifying
```bash
kubectl get pods -n devops-app
kubectl get services -n devops-app
```

---

## Phase 4 — CI/CD Pipeline (GitHub Actions)

### GitHub Secrets configured
| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | AWS authentication |
| `AWS_ACCOUNT_ID` | ECR image URL |
| `AWS_REGION` | Target region |
| `DB_PASSWORD` | RDS password |
| `DB_HOST` | RDS endpoint |
| `PGADMIN_EMAIL` | pgAdmin login |
| `PGADMIN_PASSWORD` | pgAdmin login |

### Pipeline file: `.github/workflows/deploy.yml`
Triggers on every push to `main`. Steps:
1. Checkout code
2. Configure AWS credentials
3. Login to ECR
4. Build and push React image
5. Update kubeconfig (connect to EKS)
6. Apply aws-auth configmap
7. Create/update Kubernetes secret from GitHub Secrets
8. Apply all Kubernetes manifests
9. Restart React deployment (pick up new image)

---

## CI/CD Errors and Fixes

### Error 1 — Git push rejected (workflow scope)
**Error:** `refusing to allow a Personal Access Token to create or update workflow without workflow scope`  
**Fix:** Regenerated GitHub Personal Access Token with `workflow` scope checked. Updated remote URL:
```bash
git remote set-url origin https://USERNAME:TOKEN@github.com/USERNAME/repo.git
```

### Error 2 — Invalid security token
**Error:** `The security token included in the request is invalid`  
**Cause:** Wrong AWS credentials in GitHub Secrets  
**Fix:** Created fresh IAM access key in AWS Console, updated GitHub Secrets

### Error 3 — Signature mismatch
**Error:** `The request signature we calculated does not match the signature you provided`  
**Cause:** Secret access key had copy/paste error (extra spaces or characters)  
**Fix:** Deleted and recreated the `AWS_SECRET_ACCESS_KEY` GitHub Secret with clean copy

### Error 4 — ECR permission denied
**Error:** `terraform-user is not authorized to perform: ecr:GetAuthorizationToken`  
**Fix:** Added IAM policy attachments to `terraform-user` in `main.tf`:
```hcl
resource "aws_iam_user_policy_attachment" "cicd_ecr" {
  user       = aws_iam_user.cicd.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}
```

### Error 5 — EKS DescribeCluster denied
**Error:** `terraform-user is not authorized to perform: eks:DescribeCluster`  
**Fix:** Added custom inline policy in `main.tf`:
```hcl
resource "aws_iam_user_policy" "cicd_eks_access" {
  name = "cicd-eks-access"
  user = aws_iam_user.cicd.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"]
      Resource = "*"
    }]
  })
}
```

### Error 6 — kubectl Unauthorized
**Error:** `failed to create secret UnauthorizedError`  
**Cause:** IAM permissions and Kubernetes RBAC are separate. Having IAM access to EKS doesn't automatically grant kubectl permissions inside the cluster  
**Fix:** Added `terraform-user` to the EKS `aws-auth` ConfigMap with `system:masters` group:
```yaml
mapUsers: |
  - userarn: arn:aws:iam::ACCOUNT_ID:user/terraform-user
    username: terraform-user
    groups:
      - system:masters
```
Applied via:
```bash
kubectl apply -f kubernetes/aws-auth.yaml
```

### Error 7 — aws-auth.yaml not found in pipeline
**Error:** `the path "kubernetes/aws-auth.yaml" does not exist`  
**Cause:** File was created locally but never committed to git  
**Fix:**
```bash
git add kubernetes/aws-auth.yaml
git commit -m "feat: add aws-auth configmap"
git push
```

### Error 8 — Special characters in secret values
**Error:** `--from-literal=PGADMIN_PASSWORD=***: command not found`  
**Cause:** Password contained `!` which bash interprets as a history expansion character when unquoted  
**Fix:** Wrapped all `--from-literal` values in double quotes in the workflow:
```yaml
--from-literal=PGADMIN_PASSWORD="${{ secrets.PGADMIN_PASSWORD }}"
```

### Error 9 — Workflow step pasted in wrong place
**Error:** YAML syntax error — `Apply aws-auth` step was nested inside `Update kubeconfig` step  
**Fix:** Corrected indentation and step ordering in `deploy.yml`

---

## Key Learnings

1. **IAM vs Kubernetes RBAC are separate** — AWS IAM controls who can call AWS APIs (describe cluster, push to ECR). The EKS `aws-auth` ConfigMap controls who can run `kubectl` commands inside the cluster. You need both.

2. **EKS creates two security groups** — the one you define in Terraform (`eks-sg`) and an auto-generated cluster security group. Pods use the auto-generated one, so RDS rules must allow traffic from it.

3. **Terraform state vs AWS reality can drift** — if resources are created or modified outside Terraform, use `terraform import` to sync them back into state.

4. **Never commit secrets** — use `.gitignore` for local secret files, GitHub Secrets for CI/CD, and Kubernetes Secrets (injected at runtime) for pods.

5. **Special characters in passwords break shell commands** — always quote secret values in shell scripts.

6. **Docker image must exist in ECR before Kubernetes can deploy it** — apply manifests only after the image is pushed.

7. **Namespace must be created first** — all other Kubernetes resources depend on it existing.
