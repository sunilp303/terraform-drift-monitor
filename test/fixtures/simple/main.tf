# CI fixture: local backend, no cloud credentials needed.
# Apply with the default value, then plan with -var=content=<other>
# to simulate drift (terraform plan exit code 2).
terraform {
  required_version = ">= 1.5.0"
}

variable "content" {
  type    = string
  default = "baseline"
}

resource "terraform_data" "example" {
  input = var.content
}
