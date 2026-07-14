.PHONY: lint lint-check actionlint shell-lint runtime-config-contract application-env-contract compose-runtime-contract backup-contract overlay-contract filesystem-prep-contract key-rotation-contract vault-runtime-contract managed-artifact-contract config-management-input-contract systemd-contract sitectl-version-contract go-fmt-check go-vet go-contracts template-version-contract rollout-parity-contract rootfs-package-contract host-runtime-security cos-jq-portability-contract source-trust-contract cloud-smoke-cleanup-contract hosted-cleanup-retry-contract gcp-upgrade-smoke-contract artifact-install-contract config-management-smoke cloud-compose-ci
.PHONY: terraform-fmt terraform-fmt-check terraform-validate terraform-validate-contract terraform-lint-check terraform-docs terraform-docs-check
.PHONY: config-management-cloud-smoke config-management-cloud-smoke-ansible-drupal config-management-cloud-smoke-salt-drupal
.PHONY: destroy-config-management-cloud-smoke destroy-config-management-cloud-smoke-ansible-drupal destroy-config-management-cloud-smoke-salt-drupal
.PHONY: smoke-test-clouds smoke-test smoke-test-digitalocean-isle smoke-test-linode-wp smoke-test-gcp-wp
.PHONY: destroy-smoke destroy-smoke-digitalocean-isle destroy-smoke-linode-wp destroy-smoke-gcp-wp
.PHONY: docs docs-docker-build docs-build docs-serve docs-preview docs-clean

DOCS_IMAGE ?= cloud-compose-docs
DOCS_PORT ?= 8888
DOCS_DOCKER_USER ?= $(shell id -u):$(shell id -g)
ACTIONLINT_VERSION ?= v1.7.12
TERRAFORM_DOCS_VERSION ?= v0.21.0
CLOUD_COMPOSE_CI_BIN ?= $(CURDIR)/.bin/cloud-compose-ci
export CLOUD_COMPOSE_CI_BIN
GO_MODULE_FILES := $(wildcard go.mod go.sum)
GO_SOURCES := $(shell find cmd internal -type f -name '*.go')

lint: terraform-fmt actionlint shell-lint host-runtime-security cos-jq-portability-contract application-env-contract compose-runtime-contract backup-contract overlay-contract filesystem-prep-contract key-rotation-contract vault-runtime-contract managed-artifact-contract config-management-input-contract systemd-contract source-trust-contract cloud-smoke-cleanup-contract hosted-cleanup-retry-contract gcp-upgrade-smoke-contract sitectl-version-contract template-version-contract rollout-parity-contract rootfs-package-contract artifact-install-contract terraform-validate terraform-docs-check

lint-check: terraform-fmt-check actionlint shell-lint host-runtime-security cos-jq-portability-contract application-env-contract compose-runtime-contract backup-contract overlay-contract filesystem-prep-contract key-rotation-contract vault-runtime-contract managed-artifact-contract config-management-input-contract systemd-contract source-trust-contract cloud-smoke-cleanup-contract hosted-cleanup-retry-contract gcp-upgrade-smoke-contract sitectl-version-contract template-version-contract rollout-parity-contract rootfs-package-contract artifact-install-contract terraform-validate terraform-docs-check

actionlint:
	go run github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)

terraform-fmt:
	terraform fmt -recursive

terraform-fmt-check:
	terraform fmt -check -recursive

terraform-validate: terraform-validate-contract
	bash ci/terraform-validate.sh

terraform-validate-contract:
	bash ci/terraform-validate-contract.sh

terraform-lint-check: terraform-fmt-check terraform-validate

shell-lint:
	@find . \
		-path "./.terraform" -prune -o \
		-path "./docs/site" -prune -o \
		-type f -name "*.sh" -print0 | xargs -0 shellcheck --severity=warning

runtime-config-contract:
	bash ci/runtime-config-contract.sh

application-env-contract:
	bash ci/application-env-contract.sh

compose-runtime-contract:
	bash ci/compose-runtime-contract.sh

backup-contract:
	bash ci/backup-contract.sh

overlay-contract:
	bash ci/overlay-contract.sh

filesystem-prep-contract:
	bash ci/filesystem-prep-contract.sh

key-rotation-contract:
	bash ci/key-rotation-contract.sh

vault-runtime-contract:
	bash ci/vault-runtime-contract.sh

managed-artifact-contract:
	bash ci/managed-artifact-contract.sh

config-management-input-contract:
	bash ci/config-management-input-contract.sh

systemd-contract:
	bash ci/systemd-contract.sh

sitectl-version-contract:
	bash ci/sitectl-version-contract.sh

go-fmt-check:
	@files="$$(gofmt -l .)"; test -z "$$files" || { echo "Go files require formatting:"; printf '%s\n' "$$files"; exit 1; }

go-vet:
	go vet ./...

go-contracts: go-fmt-check go-vet
	go test -count=1 ./...

template-version-contract rollout-parity-contract: go-contracts

rootfs-package-contract:
	bash ci/rootfs-package-contract.sh

host-runtime-security:
	bash ci/host-runtime-security.sh

cos-jq-portability-contract:
	bash ci/cos-jq-portability-contract.sh

source-trust-contract:
	bash ci/source-trust-contract.sh

cloud-smoke-cleanup-contract: go-contracts

cloud-compose-ci: $(CLOUD_COMPOSE_CI_BIN)

$(CLOUD_COMPOSE_CI_BIN): $(GO_MODULE_FILES) $(GO_SOURCES)
	@mkdir -p "$(dir $(CLOUD_COMPOSE_CI_BIN))"
	go build -trimpath -o "$(CLOUD_COMPOSE_CI_BIN)" ./cmd/cloud-compose-ci

gcp-upgrade-smoke-contract:
	bash ci/gcp-upgrade-smoke-contract.sh

artifact-install-contract:
	bash ci/docker-plugin-install-contract.sh
	bash ci/cos-bootstrap-contract.sh

hosted-cleanup-retry-contract:
	bash ci/hosted-cleanup-retry-contract.sh

config-management-smoke: runtime-config-contract artifact-install-contract
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
	go run github.com/terraform-docs/terraform-docs@$(TERRAFORM_DOCS_VERSION) markdown table --sort-by required --output-file README.md .

terraform-docs-check:
	go run github.com/terraform-docs/terraform-docs@$(TERRAFORM_DOCS_VERSION) markdown table --sort-by required --output-file README.md --output-check .

smoke-test-clouds: cloud-compose-ci
	ci/cloud-smoke.sh all

smoke-test:
	@test -n "$(PROVIDER)" || { echo "PROVIDER is required"; exit 2; }
	@test -n "$(TEMPLATE)" || { echo "TEMPLATE is required"; exit 2; }
	@if [ "$(PROVIDER)" = "gcp" ]; then $(MAKE) --no-print-directory cloud-compose-ci; fi
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
	@if [ "$(PROVIDER)" = "gcp" ]; then $(MAKE) --no-print-directory cloud-compose-ci; fi
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
