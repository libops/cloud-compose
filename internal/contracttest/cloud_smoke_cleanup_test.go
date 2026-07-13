package contracttest

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestCloudSmokeCleanupWorkflowTrust(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	pullRequestWorkflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke.yml")
	cleanupWorkflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke-cleanup.yml")
	docs := readRepositoryFile(t, root, "docs/runtime-contracts.md")

	for label, marker := range map[string]string{
		"pull-request event restriction": "github.event.workflow_run.event == 'pull_request'",
		"same-repository restriction":    "github.event.workflow_run.head_repository.full_name == github.repository",
		"trusted checkout":               "ref: ${{ github.sha }}",
		"originating workflow run ID":    "CLOUD_COMPOSE_SMOKE_RUN_ID: ${{ github.event.workflow_run.id }}",
		"compiled runner build":          "run: make cloud-compose-ci",
	} {
		requireContains(t, cleanupWorkflow, marker, label)
	}
	if strings.Contains(cleanupWorkflow, "github.event.workflow_run.head_sha") {
		t.Fatal("fallback cleanup checks out pull-request-controlled code")
	}
	if strings.Contains(cleanupWorkflow, "actions/download-artifact") {
		t.Fatal("privileged fallback cleanup consumes a pull-request artifact")
	}

	for _, environment := range []string{
		"cloud-smoke-cleanup-digitalocean",
		"cloud-smoke-cleanup-linode",
		"cloud-smoke-cleanup-gcp",
	} {
		if strings.Contains(pullRequestWorkflow, environment) {
			t.Errorf("pull-request-controlled workflow can request cleanup environment %s", environment)
		}
		requireContains(t, cleanupWorkflow, environment, "dedicated cleanup environment "+environment)
		requireContains(t, docs, environment, "cleanup environment documentation for "+environment)
	}

	requireContains(t, pullRequestWorkflow, "if: always()", "same-job cleanup")
	cleanupJob := regexp.MustCompile(`(?m)^  (config-management-cleanup|cleanup|gcp-cleanup):`)
	if cleanupJob.MatchString(pullRequestWorkflow) {
		t.Fatal("pull-request workflow contains a second secret-bearing cleanup job")
	}

	buildIndex := strings.Index(pullRequestWorkflow, "- name: Build cloud CI runner")
	freshIndex := strings.Index(pullRequestWorkflow, "- name: Run fresh smoke test")
	upgradeIndex := strings.Index(pullRequestWorkflow, "- name: Run 0.10.2 upgrade smoke test")
	destroyIndex := strings.Index(pullRequestWorkflow, "- name: Destroy fresh smoke resources")
	if buildIndex < 0 || freshIndex < 0 || upgradeIndex < 0 || destroyIndex < 0 ||
		buildIndex >= freshIndex || buildIndex >= upgradeIndex || buildIndex >= destroyIndex {
		t.Fatal("GCP smoke job does not build one cleanup runner before every lifecycle path")
	}
}

func TestCloudSmokeGCPWrapperUsesCompiledRunner(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	driver := readRepositoryFile(t, root, "ci/cloud-smoke.sh")
	makefile := readRepositoryFile(t, root, "Makefile")

	for label, marker := range map[string]string{
		"compiled runner path":    "CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci",
		"canonical run validator": `"$runner" gcp namespace --run-id "$run_id"`,
		"GCP sweep subcommand":    "gcp sweep",
		"owned-run flag":          `cleanup_args+=(--run-id "$run_id")`,
		"explicit orphan flag":    "cleanup_args+=(--all-runs)",
		"broad-sweep gate":        `CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS:-false`,
		"Make build target":       `go build -trimpath -o "$(CLOUD_COMPOSE_CI_BIN)" ./cmd/cloud-compose-ci`,
	} {
		requireContains(t, driver+makefile, marker, label)
	}
	for _, obsolete := range []string{
		"gcp_command_with_retry",
		"gcp_project_iam_rows",
		"gcp_smoke_residuals",
		"gcp_verify_no_smoke_resources",
	} {
		if strings.Contains(driver, obsolete) {
			t.Errorf("shell driver still owns migrated GCP behavior %s", obsolete)
		}
	}
	if strings.Contains(makefile, "go run ./cmd/cloud-compose-ci") {
		t.Fatal("cloud lifecycle uses go run instead of one compiled runner")
	}
	if _, err := os.Stat(filepath.Join(root, "ci/cloud-smoke-cleanup-contract.sh")); !os.IsNotExist(err) {
		t.Fatalf("legacy fake-gcloud Bash contract still exists: %v", err)
	}
}

func TestCloudSmokeGCPApplyRequiresCanonicalRunID(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	driverPath := filepath.Join(root, "ci/cloud-smoke.sh")
	driver := readRepositoryFile(t, root, "ci/cloud-smoke.sh")

	validation := `run_namespace="$(gcp_run_namespace "$target" "$run_id")"`
	validationIndex := strings.Index(driver, validation)
	argumentsIndex := strings.Index(driver, `mapfile -d '' -t var_args < <(target_var_args`)
	applyIndex := strings.Index(driver, `terraform -chdir="$root" apply`)
	if validationIndex < 0 || argumentsIndex < 0 || applyIndex < 0 ||
		validationIndex >= argumentsIndex || validationIndex >= applyIndex {
		t.Fatal("GCP smoke does not validate its canonical run ID before Terraform argument construction and apply")
	}

	runHelper := func(t *testing.T, target, runID string) (string, error) {
		t.Helper()
		command := exec.Command(
			"bash",
			"-c",
			`source "$1"; gcp_run_namespace "$2" "$3"`,
			"cloud-compose-contract",
			driverPath,
			target,
			runID,
		)
		output, err := command.CombinedOutput()
		return string(output), err
	}

	output, err := runHelper(t, "gcp-wp", "")
	if err == nil {
		t.Fatal("GCP run-ID guard unexpectedly accepted an empty run ID")
	}
	if !strings.Contains(output, "required for every GCP smoke apply") {
		t.Fatalf("GCP run-ID guard did not explain the failure: %s", output)
	}

	if output, err := runHelper(t, "linode-wp", ""); err != nil {
		t.Fatalf("non-GCP run-ID guard changed existing behavior: %v, output = %s", err, output)
	}
}

func TestCloudSmokeGCPWriterUsesExactRunNamespace(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	driver := readRepositoryFile(t, root, "ci/cloud-smoke.sh")
	gcpVariables := readRepositoryFile(t, root, "tests/smoke/gcp/variables.tf")
	gcpFixture := readRepositoryFile(t, root, "tests/smoke/gcp/main.tf")
	contextVariables := readRepositoryFile(t, root, "tests/smoke/modules/context/variables.tf")
	contextFixture := readRepositoryFile(t, root, "tests/smoke/modules/context/main.tf")

	for label, marker := range map[string]string{
		"compiled namespace command": `"$runner" gcp namespace --run-id "$run_id"`,
		"captured raw run ID":        `run_id="$(smoke_run_id)"`,
		"captured exact namespace":   `run_namespace="$(gcp_run_namespace "$target" "$run_id")"`,
		"raw Terraform input":        `"smoke_run_id=${run_id}"`,
		"exact Terraform input":      `"smoke_run_namespace=${run_namespace}"`,
		"raw cleanup ownership":      `provider_tag_cleanup "$target" "$run_id"`,
	} {
		requireContains(t, driver, marker, label)
	}

	namespaceIndex := strings.Index(driver, `run_namespace="$(gcp_run_namespace "$target" "$run_id")"`)
	argumentsIndex := strings.Index(driver, `mapfile -d '' -t var_args < <(target_var_args`)
	if namespaceIndex < 0 || argumentsIndex < 0 || namespaceIndex >= argumentsIndex {
		t.Fatal("fresh GCP smoke does not validate its exact namespace before Terraform argument process substitution")
	}

	for label, text := range map[string]string{
		"GCP root variables":      gcpVariables,
		"context variables":       contextVariables,
		"GCP context plumbing":    gcpFixture,
		"context naming decision": contextFixture,
	} {
		requireContains(t, text, "smoke_run_namespace", label)
	}
	requireContains(t, contextFixture, `local.cloud_provider == "gcp" ? var.smoke_run_namespace : ""`, "GCP-only exact namespace selection")
	requireContains(t, contextFixture, `local.smoke_run_id != "" ? "gha-run-${local.smoke_run_id}" : ""`, "legacy run-id cleanup tag")
}

func TestCloudSmokeGCPWrapperFailsClosedWithoutRunID(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	temporaryDirectory := t.TempDir()
	fakeRunner := filepath.Join(temporaryDirectory, "cloud-compose-ci")
	fakeGCloud := filepath.Join(temporaryDirectory, "gcloud")
	for path, content := range map[string]string{
		fakeRunner: `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_CLEANUP_LOG"
`,
		fakeGCloud: `#!/usr/bin/env bash
exit 0
`,
	} {
		if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
			t.Fatalf("write fake executable %s: %v", path, err)
		}
	}

	runWrapper := func(t *testing.T, runID string, allowAll bool) (string, string, error) {
		t.Helper()
		logPath := filepath.Join(t.TempDir(), "cleanup.log")
		overrides := map[string]string{
			"CLOUD_COMPOSE_CI_BIN":       fakeRunner,
			"CLOUD_COMPOSE_SMOKE_RUN_ID": runID,
			"FAKE_CLEANUP_LOG":           logPath,
			"GCLOUD_PROJECT":             "test-project",
			"GCLOUD_REGION":              "us-east5",
			"PATH":                       temporaryDirectory + string(os.PathListSeparator) + os.Getenv("PATH"),
		}
		if allowAll {
			overrides["CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS"] = "true"
		} else {
			overrides["CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS"] = "false"
		}
		command := exec.Command("bash", filepath.Join(root, "ci/cloud-smoke.sh"), "sweep-gcp-wp")
		command.Env = overriddenEnvironment(overrides)
		output, err := command.CombinedOutput()
		logged, readErr := os.ReadFile(logPath)
		if readErr != nil && !os.IsNotExist(readErr) {
			t.Fatalf("read fake cleanup log: %v", readErr)
		}
		return string(output), string(logged), err
	}

	t.Run("owned run", func(t *testing.T) {
		output, logged, err := runWrapper(t, "123456789", false)
		if err != nil {
			t.Fatalf("wrapper error = %v, output = %s", err, output)
		}
		if !strings.Contains(logged, "--run-id\n123456789\n") || strings.Contains(logged, "--all-runs") {
			t.Fatalf("wrapper did not preserve run ownership:\n%s", logged)
		}
	})

	t.Run("missing scope", func(t *testing.T) {
		output, logged, err := runWrapper(t, "", false)
		if err == nil {
			t.Fatal("wrapper unexpectedly allowed an unscoped cleanup")
		}
		if logged != "" {
			t.Fatalf("wrapper invoked cleanup before establishing ownership:\n%s", logged)
		}
		if !strings.Contains(output, "requires CLOUD_COMPOSE_SMOKE_RUN_ID") {
			t.Fatalf("wrapper did not explain the ownership failure:\n%s", output)
		}
	})

	t.Run("explicit all runs", func(t *testing.T) {
		output, logged, err := runWrapper(t, "", true)
		if err != nil {
			t.Fatalf("wrapper error = %v, output = %s", err, output)
		}
		if !strings.Contains(logged, "--all-runs\n") || strings.Contains(logged, "--run-id") {
			t.Fatalf("wrapper did not pass the explicit broad-cleanup flag:\n%s", logged)
		}
	})
}

func overriddenEnvironment(overrides map[string]string) []string {
	environment := make([]string, 0, len(os.Environ())+len(overrides))
	for _, entry := range os.Environ() {
		name, _, found := strings.Cut(entry, "=")
		if found {
			if _, overridden := overrides[name]; overridden {
				continue
			}
		}
		environment = append(environment, entry)
	}
	for name, value := range overrides {
		environment = append(environment, name+"="+value)
	}
	return environment
}
