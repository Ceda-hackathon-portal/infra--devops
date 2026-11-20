variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "ceda-portal"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "Primary AWS region. af-south-1 (Cape Town) is closest to Botswana and must be enabled on the account."
  type        = string
  default     = "af-south-1"
}

variable "github_org" {
  description = "GitHub organisation whose repositories may assume the deploy roles through OIDC."
  type        = string
  default     = "Ceda-hackathon-portal"
}
