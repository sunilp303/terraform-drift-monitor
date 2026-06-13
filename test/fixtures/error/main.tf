# CI fixture: deliberately broken config so terraform plan exits 1,
# exercising the "drift check itself is broken" alerting path.
terraform {
  required_version = ">= 1.5.0"
}

resource "terraform_data" "broken" {
  input = var.does_not_exist
}
