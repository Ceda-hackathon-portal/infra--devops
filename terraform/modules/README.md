# Modules

Reusable Terraform modules called from `envs/<environment>/`. Suggested split:

| Module | Creates |
| --- | --- |
| `github-oidc` | GitHub OIDC identity provider and one least-privilege deploy role per repository |
| `static-site` | Private S3 bucket, CloudFront distribution with Origin Access Control, SPA error responses, ACM certificate |
| `api-service` | ECR repository, ECS cluster, Fargate service and task definition, Application Load Balancer, security groups |
| `database` | RDS PostgreSQL in private subnets, credentials in Secrets Manager |
| `network` | VPC, public and private subnets, NAT |
