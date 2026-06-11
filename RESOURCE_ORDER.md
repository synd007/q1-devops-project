# Terraform Resource Creation Order

Terraform resolves dependencies automatically, but this is the order resources are built based on those dependencies.

---

1.  `aws_vpc`                              — the network container everything lives in
2.  `aws_subnet` × 4                       — pub1, pub2, priv1, priv2 inside the VPC
3.  `aws_internet_gateway`                 — door to the internet, attached to VPC
4.  `aws_route_table`                      — routing rules for public subnets
5.  `aws_route_table_association` × 2      — links pub1 and pub2 to the route table
6.  `aws_security_group` (eks-sg)          — firewall for EKS cluster (port 443)
7.  `aws_security_group` (rds-sg)          — firewall for RDS (port 5432 from EKS only)
8.  `aws_db_subnet_group`                  — tells RDS which subnets to use (priv1, priv2)
9.  `aws_ecr_repository`                   — private Docker image registry
10. `aws_iam_role` (eks-cluster-role)      — identity for the EKS control plane
11. `aws_iam_role` (eks-node-role)         — identity for EC2 worker nodes
12. `aws_iam_role_policy_attachment` × 4   — attaches AWS managed policies to both roles
13. `aws_iam_user` (terraform-user)        — IAM user for CI/CD pipeline
14. `aws_iam_user_policy_attachment` × 3   — attaches ECR and EKS policies to CI/CD user
15. `aws_iam_user_policy`                  — inline policy for eks:DescribeCluster etc.
16. `aws_eks_cluster`                      — Kubernetes control plane (needs IAM role + policies)
17. `aws_db_instance`                      — RDS PostgreSQL (needs subnet group + security group)
18. `aws_eks_node_group`                   — EC2 worker nodes (needs cluster + IAM attachments)

---

## Notes

- Terraform does NOT always follow this exact order in parallel — it runs independent resources concurrently
- Resources with no dependencies (like `aws_ecr_repository` and `aws_vpc`) can be created at the same time
- `aws_eks_cluster` must wait for IAM policy attachments (`depends_on` is explicitly set)
- `aws_eks_node_group` must wait for the cluster and all three node IAM policy attachments
- `aws_security_group.rds` references `aws_eks_cluster.main.vpc_config[0].cluster_security_group_id` — this means RDS security group update depends on EKS cluster being created first
