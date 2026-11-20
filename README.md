# CEDA Innovation Portal: infra--devops

Terraform for every AWS resource behind the CEDA Innovation Portal, plus the shared deployment conventions for the other repositories.

- [front-end](https://github.com/Ceda-hackathon-portal/front-end): static site on S3 + CloudFront
- [backend-api](https://github.com/Ceda-hackathon-portal/backend-api): container on ECS Fargate behind an Application Load Balancer

## Target architecture

```text
Browser ──HTTPS──> CloudFront ──(Origin Access Control)──> S3 (private): front-end build
   │
   └──HTTPS──> Application Load Balancer ──> ECS Fargate: backend-api ──> RDS PostgreSQL (private subnets)
                                                    │
                                                    └──> S3: submission attachments, Secrets Manager: credentials

GitHub Actions ──OIDC──> IAM deploy role per repository (no long-lived AWS keys)
```

Primary region: `af-south-1` (Cape Town), the closest region to Botswana. It is an opt-in region, so enable it on the account first. CloudFront certificates must be issued in `us-east-1`, which is why `providers.tf` defines a second provider alias.

## Layout

```text
terraform/
  envs/production/     root module: backend, providers, variables, module calls
  modules/             reusable modules (planned split in modules/README.md)
```

Requires Terraform 1.10 or newer. State lives in S3 with native locking (`use_lockfile`), so no DynamoDB table is needed.

## First-time setup

1. Enable `af-south-1` on the AWS account.
2. Create the state bucket once, by hand or with a small bootstrap stack: versioning on, public access blocked, encryption on.
3. Copy `terraform/envs/production/backend.hcl.example` to `backend.hcl` and fill in the bucket name.
4. Initialise and plan:

   ```powershell
   cd terraform/envs/production
   terraform init -backend-config=backend.hcl
   terraform plan
   ```

5. Commit the generated `.terraform.lock.hcl` so every machine and CI use the same provider versions.

## Handoff to the application repositories

After `apply`, set these on the `production` GitHub environment of each repository (Settings → Environments → production). Expose each one as a Terraform output so nobody has to copy values from the console.

| Repository | Kind | Name | Terraform output |
| --- | --- | --- | --- |
| front-end | Secret | `AWS_DEPLOY_ROLE_ARN` | front-end deploy role ARN |
| front-end | Variable | `S3_BUCKET` | site bucket name |
| front-end | Variable | `CLOUDFRONT_DISTRIBUTION_ID` | distribution ID |
| front-end | Variable | `SITE_URL`, `VITE_API_URL`, `AWS_REGION` | public URLs and region |
| backend-api | Secret | `AWS_DEPLOY_ROLE_ARN` | API deploy role ARN |
| backend-api | Variable | `ECR_REPOSITORY` | repository name |
| backend-api | Variable | `ECS_CLUSTER`, `ECS_SERVICE` | cluster and service names |
| backend-api | Variable | `ECS_TASK_DEFINITION`, `ECS_CONTAINER_NAME` | task family and container name |
| backend-api | Variable | `API_URL`, `AWS_REGION` | public URL and region |

The deploy workflows in both repositories stay skipped until these are set.

## Security baseline

- **OIDC trust:** each deploy role trusts only `repo:Ceda-hackathon-portal/<repo>:environment:production` with audience `sts.amazonaws.com`.
- **Least privilege:** the front-end role may write to its bucket and create invalidations on its distribution, nothing else. The API role may push to its ECR repository, register task definitions, update its service and pass only its task roles.
- **Private storage:** the site bucket blocks public access and is read only by CloudFront through Origin Access Control. The attachments bucket is private, encrypted and reached only by the API.
- **Secrets:** stored in Secrets Manager or SSM Parameter Store and injected into ECS tasks. Never stored in Terraform variables files, Git or container images.
- **CloudFront:** HTTPS only. Map 403 and 404 to `/index.html` with status 200 so front-end routes survive a refresh.
- **Data protection:** keep personal data in `af-south-1`, encrypt at rest, and set log retention deliberately (Botswana Data Protection Act, 2024).

## CI

`terraform.yml` runs `terraform fmt -check` and `terraform validate` on every pull request and push to `main`. It needs no AWS access. To add a `plan` on pull requests and an approval-gated `apply` on `main`, create a separate plan role through OIDC.

## Branching and reviews

`main` reflects what is applied in production. Change infrastructure through pull requests, paste the `terraform plan` summary into the description, and apply only after the PR is approved.
