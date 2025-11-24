.PHONY: docs lint

lint:
	@find . -type f -name "*.tf" -exec terraform fmt {} +
	@find . -type f -name "*.sh" -exec shellcheck {} +

docs:
	terraform-docs markdown table --output-file README.md .

