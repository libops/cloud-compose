.PHONY: lint lint-check shell-lint config-management-smoke
.PHONY: terraform-fmt terraform-fmt-check terraform-validate terraform-lint-check terraform-docs
.PHONY: config-management-cloud-smoke config-management-cloud-smoke-ansible-drupal config-management-cloud-smoke-salt-drupal
.PHONY: destroy-config-management-cloud-smoke destroy-config-management-cloud-smoke-ansible-drupal destroy-config-management-cloud-smoke-salt-drupal
.PHONY: smoke-test-clouds smoke-test smoke-test-digitalocean-isle smoke-test-linode-wp smoke-test-gcp-wp
.PHONY: destroy-smoke destroy-smoke-digitalocean-isle destroy-smoke-linode-wp destroy-smoke-gcp-wp
.PHONY: docs docs-docker-build docs-build docs-serve docs-preview docs-clean

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

config-management-smoke:
	ci/config-management-smoke.sh

config-management-cloud-smoke:
	@test -n "$(METHOD)" || { echo "METHOD is required"; exit 2; }
	ci/config-management-cloud-smoke.sh $(METHOD)-drupal

config-management-cloud-smoke-ansible-drupal:
	$(MAKE) config-management-cloud-smoke METHOD=ansible

config-management-cloud-smoke-salt-drupal:
	$(MAKE) config-management-cloud-smoke METHOD=salt

destroy-config-management-cloud-smoke:
	@test -n "$(METHOD)" || { echo "METHOD is required"; exit 2; }
	ci/config-management-cloud-smoke.sh destroy-$(METHOD)-drupal

destroy-config-management-cloud-smoke-ansible-drupal:
	$(MAKE) destroy-config-management-cloud-smoke METHOD=ansible

destroy-config-management-cloud-smoke-salt-drupal:
	$(MAKE) destroy-config-management-cloud-smoke METHOD=salt

terraform-docs:
	terraform-docs markdown table --sort-by required --output-file README.md .

smoke-test-clouds:
	ci/cloud-smoke.sh all

smoke-test:
	@test -n "$(PROVIDER)" || { echo "PROVIDER is required"; exit 2; }
	@test -n "$(TEMPLATE)" || { echo "TEMPLATE is required"; exit 2; }
	ci/cloud-smoke.sh $(PROVIDER)-$(TEMPLATE)

smoke-test-digitalocean-isle:
	$(MAKE) smoke-test PROVIDER=digitalocean TEMPLATE=isle

smoke-test-linode-wp:
	$(MAKE) smoke-test PROVIDER=linode TEMPLATE=wp

smoke-test-gcp-wp:
	$(MAKE) smoke-test PROVIDER=gcp TEMPLATE=wp

destroy-smoke:
	@test -n "$(PROVIDER)" || { echo "PROVIDER is required"; exit 2; }
	@test -n "$(TEMPLATE)" || { echo "TEMPLATE is required"; exit 2; }
	ci/cloud-smoke.sh destroy-$(PROVIDER)-$(TEMPLATE)

destroy-smoke-digitalocean-isle:
	$(MAKE) destroy-smoke PROVIDER=digitalocean TEMPLATE=isle

destroy-smoke-linode-wp:
	$(MAKE) destroy-smoke PROVIDER=linode TEMPLATE=wp

destroy-smoke-gcp-wp:
	$(MAKE) destroy-smoke PROVIDER=gcp TEMPLATE=wp

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
