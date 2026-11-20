# Partial configuration: the bucket, key and region are supplied at init time with
#   terraform init -backend-config=backend.hcl
# Copy backend.hcl.example to backend.hcl and fill it in. backend.hcl is git-ignored.
terraform {
  backend "s3" {}
}
