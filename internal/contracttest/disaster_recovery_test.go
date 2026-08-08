package contracttest

import (
	"strings"
	"testing"
)

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
		requireContains(t, content, `driver_path = optional(string, "/usr/local/libexec/cloud-compose/offhost-backup-driver")`, relativePath+" driver default")
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

func TestDisasterRecoveryReceiptAndRestoreContracts(t *testing.T) {
	root := repositoryRoot(t)
	library := readRepositoryFile(t, root, "rootfs/home/cloud-compose/disaster-recovery-lib.sh")
	backup := readRepositoryFile(t, root, "rootfs/home/cloud-compose/offhost-backup.sh")
	restore := readRepositoryFile(t, root, "rootfs/home/cloud-compose/restore-test.sh")
	validationContract := strings.Join([]string{
		library,
		readRepositoryFile(t, root, "rootfs/usr/local/share/cloud-compose/jq/dr-validate-backup-receipt.jq"),
		readRepositoryFile(t, root, "rootfs/usr/local/share/cloud-compose/jq/dr-validate-restore-proof.jq"),
	}, "\n")
	backupContract := strings.Join([]string{
		backup,
		readRepositoryFile(t, root, "rootfs/usr/local/share/cloud-compose/jq/offhost-build-application-coverage.jq"),
	}, "\n")

	for marker, label := range map[string]string{
		`env -i HOME=/root`:                         "clean driver environment",
		`>/dev/null 2>&1`:                           "suppressed driver output",
		`cloud-compose.offhost-backup-receipt`:      "backup receipt kind",
		`.encrypted == true`:                        "encrypted coverage",
		`.off_host == true`:                         "off-host coverage",
		`.database == true`:                         "database coverage",
		`.application_files == true`:                "application-file coverage",
		`.volume_topology == true`:                  "volume-topology coverage",
		`cloud-compose.restore-test-proof`:          "restore proof kind",
		`.disposable_recovery == true`:              "disposable recovery proof",
		`.recovery_destroyed == true`:               "recovery cleanup proof",
		`.source_receipt_sha256 == $receipt_sha256`: "source receipt binding",
	} {
		requireContains(t, validationContract, marker, label)
	}

	for marker, label := range map[string]string{
		`docker compose config --format json`: "resolved Compose topology",
		`local_recovery_artifact`:             "logical database artifact",
		`application_files`:                   "application files",
		`volume_topology`:                     "volume topology",
		`cloud_compose_dr_run_driver`:         "provider-neutral backup handoff",
	} {
		requireContains(t, backupContract, marker, label)
	}

	for marker, label := range map[string]string{
		`/dev/urandom`:     "one-time restore challenge",
		`--backup-receipt`: "remote receipt input",
		`cloud_compose_dr_validate_restore_proof`: "strict restore proof validation",
		`mv -- "$staged_proof" "$proof_path"`:     "atomic restore proof publication",
	} {
		requireContains(t, restore, marker, label)
	}

	for _, forbidden := range []string{"AWS_ACCESS_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_STORAGE_KEY"} {
		if strings.Contains(library+backup+restore, forbidden) {
			t.Errorf("disaster-recovery runtime hard-codes credential channel %q", forbidden)
		}
	}
}
