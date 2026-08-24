package contracttest

import "testing"

func TestDisasterRecoveryInputParity(t *testing.T) {
	root := repositoryRoot(t)

	for _, relativePath := range []string{
		"variables.tf",
		"providers/gcp/variables.tf",
		"providers/do/variables.tf",
		"providers/linode/variables.tf",
		"modules/digitalocean/variables.tf",
		"modules/linode/variables.tf",
	} {
		content := readRepositoryFile(t, root, relativePath)
		requireContains(t, content, "disaster_recovery = optional(object({", relativePath+" disaster-recovery object")
		requireContains(t, content, "required    = optional(bool, false)", relativePath+" required switch")
		requireContains(t, content, `driver_path = optional(string, "/etc/cloud-compose/libexec/offhost-backup-driver")`, relativePath+" driver default")
		requireContains(t, content, "runtime.disaster_recovery.driver_path must be a safe absolute path", relativePath+" path validation")
	}

	for _, relativePath := range []string{
		"main.tf",
		"providers/gcp/main.tf",
		"modules/digitalocean/main.tf",
		"modules/linode/main.tf",
	} {
		content := readRepositoryFile(t, root, relativePath)
		requireContains(t, content, "offhost_backup_required", relativePath+" required forwarding")
		requireContains(t, content, "offhost_backup_driver_path", relativePath+" driver forwarding")
	}

	for _, relativePath := range []string{
		"modules/gcp/main.tf",
		"modules/linux-vm-runtime/main.tf",
		"ansible/roles/cloud_compose/tasks/main.yml",
		"salt/cloud-compose/init.sls",
	} {
		content := readRepositoryFile(t, root, relativePath)
		requireContains(t, content, "CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED", relativePath+" required host control")
		requireContains(t, content, "CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER", relativePath+" driver host control")
	}
}
