package contracttest

import (
	"strings"
	"testing"
)

func TestRootEntrypointLoadsOnlyGCPProviders(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	rootConfiguration := strings.Join([]string{
		readRepositoryFile(t, root, "main.tf"),
		readRepositoryFile(t, root, "variables.tf"),
		readRepositoryFile(t, root, "outputs.tf"),
	}, "\n")

	for _, forbidden := range []string{
		"digitalocean/digitalocean",
		"linode/linode",
		`source = "./modules/digitalocean"`,
		`source = "./modules/linode"`,
		`variable "digitalocean"`,
		`variable "linode"`,
		"module.digitalocean",
		"module.linode",
	} {
		if strings.Contains(rootConfiguration, forbidden) {
			t.Errorf("root GCP entrypoint contains non-GCP dependency %q", forbidden)
		}
	}

	for path, providerSource := range map[string]string{
		"providers/gcp/main.tf":    "hashicorp/google",
		"providers/do/main.tf":     "digitalocean/digitalocean",
		"providers/linode/main.tf": "linode/linode",
	} {
		requireContains(t, readRepositoryFile(t, root, path), providerSource, path+" provider ownership")
	}

	publicOutputs := []string{
		"cloud_provider",
		"template",
		"instance",
		"instance_id",
		"external_ip",
		"internal_ip",
		"network",
		"volumes",
		"serviceGsa",
		"appGsa",
		"urls",
		"backend",
		"rollout",
		"compose_projects",
		"primary_compose_project",
		"sitectl_package_versions",
	}
	for _, path := range []string{
		"outputs.tf",
		"providers/gcp/outputs.tf",
		"providers/do/outputs.tf",
		"providers/linode/outputs.tf",
	} {
		content := readRepositoryFile(t, root, path)
		for _, output := range publicOutputs {
			requireContains(t, content, `output "`+output+`"`, path+" public output parity")
		}
	}

	validator := readRepositoryFile(t, root, "ci/terraform-validate.sh")
	for _, marker := range []string{
		"terraform -chdir=\"$root\" providers",
		"digitalocean/digitalocean",
		"hashicorp/cloudinit",
		"hashicorp/google",
		"hashicorp/time",
		"linode/linode",
		"Unexpected Terraform provider graph",
	} {
		requireContains(t, validator, marker, "transitive provider-graph validation")
	}

	migrationDocs := readRepositoryFile(t, root, "docs/non-gcp-providers.md")
	for _, marker := range []string{
		"module.site.module.digitalocean[0]",
		"module.site.module.digitalocean",
		"module.site.module.linode[0]",
		"module.site.module.linode",
		"must show the existing VM,",
		"both durable volumes moving addresses without replacement",
	} {
		requireContains(t, migrationDocs, marker, "root 1.x provider-entrypoint migration")
	}
}
