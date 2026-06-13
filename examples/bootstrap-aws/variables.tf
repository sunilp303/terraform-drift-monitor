variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "Repository allowed to assume the role, as org/repo (e.g. acme/infra)."
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role assumed by the drift-detection workflow."
  type        = string
  default     = "gha-drift-detector"
}

variable "state_bucket" {
  description = "Name of the S3 bucket holding your Terraform state."
  type        = string
}

variable "audit_bucket_name" {
  description = "Globally unique name for the new drift-audit S3 bucket."
  type        = string
}

variable "create_oidc_provider" {
  description = "Set to false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}
