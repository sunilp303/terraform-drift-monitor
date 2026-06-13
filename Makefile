SHELL := /bin/bash
.PHONY: install lint validate test fmt clean

install: ## Check required tooling is present
	@for t in bash jq shellcheck terraform; do \
		command -v $$t >/dev/null || echo "MISSING: $$t"; \
	done; echo "Tool check complete."

lint: ## Shellcheck all action scripts
	shellcheck scripts/*.sh

validate: ## Validate fixture and example Terraform
	cd test/fixtures/simple && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd examples/bootstrap-aws && terraform init -backend=false -input=false >/dev/null && terraform validate

fmt: ## Format Terraform in fixtures and examples
	terraform fmt -recursive test examples

test: lint validate ## Lint + validate (the full action self-test runs in CI)

clean: ## Remove local Terraform artifacts
	rm -rf test/fixtures/*/.terraform test/fixtures/*/terraform.tfstate* \
		examples/bootstrap-aws/.terraform
