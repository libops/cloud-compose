.PHONY: lint lint-check terraform-fmt terraform-fmt-check terraform-validate terraform-lint-check shell-lint terraform-docs smoke-test-clouds smoke-test-digitalocean-isle smoke-test-linode-wp smoke-test-gcp-wp destroy-smoke-digitalocean-isle destroy-smoke-linode-wp destroy-smoke-gcp-wp docs docs-docker-build docs-build docs-serve docs-preview docs-clean

DOCS_IMAGE ?= cloud-compose-docs
DOCS_PORT ?= 8888
DOCS_DOCKER_USER ?= $(shell id -u):$(shell id -g)

lint: terraform-fmt shell-lint terraform-validate

lint-check: terraform-fmt-check shell-lint terraform-validate

terraform-fmt:
	terraform fmt -recursive

terraform-fmt-check:
	terraform fmt -check -recursive

terraform-validate:
	bash ci/terraform-validate.sh

terraform-lint-check: terraform-fmt-check terraform-validate

shell-lint:
	@find . \
		-path "./.terraform" -prune -o \
		-path "./docs/site" -prune -o \
		-type f -name "*.sh" -print0 | xargs -0 shellcheck

terraform-docs:
	terraform-docs markdown table --sort-by required --output-file README.md .

smoke-test-clouds:
	ci/cloud-smoke.sh all

smoke-test-digitalocean-isle:
	ci/cloud-smoke.sh digitalocean-isle

smoke-test-linode-wp:
	ci/cloud-smoke.sh linode-wp

smoke-test-gcp-wp:
	ci/cloud-smoke.sh gcp-wp

destroy-smoke-digitalocean-isle:
	ci/cloud-smoke.sh destroy-digitalocean-isle

destroy-smoke-linode-wp:
	ci/cloud-smoke.sh destroy-linode-wp

destroy-smoke-gcp-wp:
	ci/cloud-smoke.sh destroy-gcp-wp

docs: docs-build

docs-docker-build:
	docker build -f docs/Dockerfile -t $(DOCS_IMAGE) .

docs-build: docs-docker-build
	rm -rf site docs/site
	docker run --rm \
		-u "$(DOCS_DOCKER_USER)" \
		$(if $(SITE_URL),-e SITE_URL=$(SITE_URL)) \
		-v "$(CURDIR):/work" \
		-w /work \
		$(DOCS_IMAGE) \
		build --clean --config-file docs/mkdocs.yml

docs-serve: docs-docker-build
	docker run --rm -it \
		-u "$(DOCS_DOCKER_USER)" \
		-p $(DOCS_PORT):8080 \
		-v "$(CURDIR):/work" \
		-w /work \
		$(DOCS_IMAGE) \
		serve --config-file docs/mkdocs.yml --dev-addr 0.0.0.0:8080

docs-preview:
	$(MAKE) docs-build SITE_URL=http://localhost:$(DOCS_PORT)
	docker run --rm -it \
		-p $(DOCS_PORT):8080 \
		-v "$(CURDIR)/docs/site:/site" \
		-w /site \
		--entrypoint python3 \
		$(DOCS_IMAGE) \
		-m http.server 8080

docs-clean:
	rm -rf site docs/site
