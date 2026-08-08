package contracttest

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
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

func TestNonGCPSmokeCleanupUsesCompiledRunner(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	appDriver := readRepositoryFile(t, root, "ci/cloud-smoke.sh")
	configDriver := readRepositoryFile(t, root, "ci/config-management-cloud-smoke.sh")
	hostedContract := readRepositoryFile(t, root, "ci/hosted-cleanup-retry-contract.sh")
	makefile := readRepositoryFile(t, root, "Makefile")
	workflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke.yml")
	cleanupWorkflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke-cleanup.yml")

	for label, marker := range map[string]string{
		"app provider command":      `"$provider" sweep`,
		"app cleanup scope":         `--scope application`,
		"config provider command":   `linode sweep`,
		"config cleanup scope":      `--scope config-management`,
		"owned-run flag":            `cleanup_args+=(--run-id "$run_id")`,
		"explicit broad-sweep flag": `cleanup_args+=(--all-runs)`,
	} {
		requireContains(t, appDriver+configDriver, marker, label)
	}
	for label, driver := range map[string]string{
		"application":       appDriver,
		"config-management": configDriver,
	} {
		requireContains(t, driver, `"$runner" run validate --run-id "$run_id"`, label+" canonical run-ID command")
		validationIndex := strings.Index(driver, `validate_smoke_run_id "$run_id"`)
		argumentsIndex := strings.Index(driver, `mapfile -d '' -t var_args < <(target_var_args`)
		applyIndex := strings.Index(driver, `terraform -chdir="$root" apply`)
		if validationIndex < 0 || argumentsIndex < 0 || applyIndex < 0 || validationIndex >= argumentsIndex || validationIndex >= applyIndex {
			t.Errorf("%s writer does not validate exact run ownership before Terraform argument construction and apply", label)
		}
	}
	for _, obsolete := range []string{
		"api_request()",
		"api_get()",
		"api_delete()",
		"delete_ids()",
		"provider_resource_ids()",
		"provider_cleanup_residuals()",
		"verify_no_provider_resources()",
		"Authorization: Bearer",
	} {
		if strings.Contains(appDriver, obsolete) || strings.Contains(configDriver, obsolete) {
			t.Errorf("shell driver still owns migrated provider API behavior %q", obsolete)
		}
	}
	for _, obsolete := range []string{
		"FAKE_API_MODE",
		"normal_get_body",
		"api.digitalocean.com",
		"api.linode.com",
	} {
		if strings.Contains(hostedContract, obsolete) {
			t.Errorf("hosted lifecycle shell contract still emulates provider HTTP behavior %q", obsolete)
		}
	}
	if strings.Contains(appDriver+configDriver+workflow+cleanupWorkflow, "--token") {
		t.Fatal("provider token is passed as a process argument")
	}

	for label, marker := range map[string]string{
		"app Make dependency":               "smoke-test: cloud-compose-ci",
		"app destroy Make dependency":       "destroy-smoke: cloud-compose-ci",
		"config-management Make dependency": "config-management-cloud-smoke: cloud-compose-ci",
		"hosted runner build":               "- name: Build provider cloud CI runner",
		"trusted cleanup runner build":      "- name: Build trusted cloud CI runner",
		"hosted Go implementation contract": "hosted-cleanup-retry-contract: go-contracts",
		"hosted fake-runner boundary":       `CLOUD_COMPOSE_CI_BIN="$tmp/bin/cloud-compose-ci"`,
	} {
		requireContains(t, makefile+workflow+cleanupWorkflow+hostedContract, marker, label)
	}
	if !regexp.MustCompile(`(?m)^hosted-cleanup-retry-contract: go-contracts$`).MatchString(makefile) {
		t.Fatal("hosted cleanup contract must test Go directly without building a workspace runner")
	}
	if strings.Contains(hostedContract, ".bin/cloud-compose-ci") || strings.Contains(hostedContract, "go run") {
		t.Fatal("hosted lifecycle contract can discover or execute an untrusted workspace runner")
	}

	for _, shellContract := range []string{
		"ci/config-management-cloud-smoke-inner.sh",
		"ci/host-runtime-security.sh",
		"ci/systemd-contract.sh",
	} {
		if _, err := os.Stat(filepath.Join(root, shellContract)); err != nil {
			t.Errorf("host/runtime black-box shell contract %s is missing: %v", shellContract, err)
		}
	}
}

func TestHostedProviderTokensAreScopedToLifecycleSteps(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	workflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke.yml")
	cleanupWorkflow := readRepositoryFile(t, root, ".github/workflows/cloud-smoke-cleanup.yml")

	configJob := workflowJobSection(t, workflow, "config-management-cloud-smoke", "smoke")
	providerJob := workflowJobSection(t, workflow, "smoke", "gcp-smoke")
	cleanupJob := workflowJobSection(t, cleanupWorkflow, "cleanup", "gcp-cleanup")

	for name, job := range map[string]string{
		"config-management smoke": configJob,
		"provider smoke":          providerJob,
		"trusted cleanup":         cleanupJob,
	} {
		stepsIndex := strings.Index(job, "\n    steps:\n")
		if stepsIndex < 0 {
			t.Fatalf("%s job has no steps boundary", name)
		}
		header := job[:stepsIndex]
		if strings.Contains(header, "DIGITALOCEAN_TOKEN:") || strings.Contains(header, "LINODE_TOKEN:") {
			t.Errorf("%s exposes a long-lived provider token at job scope", name)
		}
		requireContains(t, job, "persist-credentials: false", name+" checkout credential isolation")
	}

	configToken := "          LINODE_TOKEN: ${{ secrets.LINODE_TOKEN }}"
	if got := strings.Count(configJob, configToken); got != 2 {
		t.Fatalf("config-management token bindings = %d; want exactly the smoke and always-destroy steps", got)
	}
	for label, marker := range map[string]string{
		"config-management smoke token": `      - name: Run Linode config-management smoke test
        env:
          LINODE_TOKEN: ${{ secrets.LINODE_TOKEN }}`,
		"config-management destroy token": `      - name: Destroy Linode config-management smoke resources
        if: always()
        env:
          LINODE_TOKEN: ${{ secrets.LINODE_TOKEN }}`,
	} {
		requireContains(t, configJob, marker, label)
	}

	providerTokenEnvironment := `        env:
          DIGITALOCEAN_TOKEN: ${{ matrix.provider == 'digitalocean' && secrets.DIGITALOCEAN_TOKEN || '' }}
          LINODE_TOKEN: ${{ matrix.provider == 'linode' && secrets.LINODE_TOKEN || '' }}`
	if got := strings.Count(providerJob, providerTokenEnvironment); got != 2 {
		t.Fatalf("provider token environments = %d; want exactly the smoke and always-destroy steps", got)
	}
	for _, token := range []string{"DIGITALOCEAN_TOKEN:", "LINODE_TOKEN:"} {
		if got := strings.Count(providerJob, token); got != 2 {
			t.Fatalf("provider smoke %s bindings = %d; want 2", token, got)
		}
	}
	for label, marker := range map[string]string{
		"provider smoke tokens": `      - name: Run smoke test
` + providerTokenEnvironment,
		"provider destroy tokens": `      - name: Destroy smoke resources
        if: always()
` + providerTokenEnvironment,
	} {
		requireContains(t, providerJob, marker, label)
	}

	for label, marker := range map[string]string{
		"application sweep token": `      - name: Sweep provider smoke resources
        if: matrix.kind == 'app'
        env:
          DIGITALOCEAN_TOKEN: ${{ matrix.provider == 'digitalocean' && secrets.DIGITALOCEAN_TOKEN || '' }}
          LINODE_TOKEN: ${{ matrix.provider == 'linode' && secrets.LINODE_TOKEN || '' }}`,
		"config-management sweep token": `      - name: Sweep config-management smoke resources
        if: matrix.kind == 'config-management'
        env:
          LINODE_TOKEN: ${{ secrets.LINODE_TOKEN }}`,
	} {
		requireContains(t, cleanupJob, marker, label)
	}
	for token, want := range map[string]int{
		"DIGITALOCEAN_TOKEN:": 1,
		"LINODE_TOKEN:":       2,
	} {
		if got := strings.Count(cleanupJob, token); got != want {
			t.Fatalf("trusted cleanup %s bindings = %d; want %d lifecycle-step bindings", token, got, want)
		}
	}
	if got := strings.Count(cleanupWorkflow, "persist-credentials: false"); got != 2 {
		t.Fatalf("trusted cleanup checkout credential-isolation settings = %d; want 2", got)
	}
}

func TestNonGCPCompatibilityWrappersPassOnlyOwnershipArguments(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	temporaryDirectory := t.TempDir()
	fakeRunner := filepath.Join(temporaryDirectory, "cloud-compose-ci")
	// #nosec G306 -- the test fixture must be executable by the child process.
	if err := os.WriteFile(fakeRunner, []byte(`#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_CLEANUP_LOG"
`), 0o700); err != nil {
		t.Fatalf("write fake cleanup runner: %v", err)
	}

	tests := []struct {
		name       string
		driver     string
		command    string
		tokenName  string
		tokenValue string
		want       []string
	}{
		{
			name:       "DigitalOcean app",
			driver:     "ci/cloud-smoke.sh",
			command:    "sweep-digitalocean-isle",
			tokenName:  "DIGITALOCEAN_TOKEN",
			tokenValue: "do-wrapper-secret",
			want:       []string{"digitalocean", "sweep", "--scope", "application", "--target", "digitalocean-isle", "--run-id", "123456789"},
		},
		{
			name:       "Linode config management",
			driver:     "ci/config-management-cloud-smoke.sh",
			command:    "sweep-ansible-drupal",
			tokenName:  "LINODE_TOKEN",
			tokenValue: "linode-wrapper-secret",
			want:       []string{"linode", "sweep", "--scope", "config-management", "--target", "ansible-drupal", "--run-id", "123456789"},
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			logPath := filepath.Join(t.TempDir(), "cleanup.log")
			command := exec.Command("bash", filepath.Join(root, test.driver), test.command)
			command.Env = overriddenEnvironment(map[string]string{
				"CLOUD_COMPOSE_CI_BIN":       fakeRunner,
				"CLOUD_COMPOSE_SMOKE_RUN_ID": "123456789",
				"FAKE_CLEANUP_LOG":           logPath,
				test.tokenName:               test.tokenValue,
			})
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("wrapper error = %v, output = %s", err, output)
			}
			logged, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatalf("read cleanup log: %v", err)
			}
			got := strings.Fields(string(logged))
			if !slices.Equal(got, test.want) {
				t.Fatalf("runner arguments = %q; want %q", got, test.want)
			}
			if strings.Contains(string(logged), test.tokenValue) || strings.Contains(string(output), test.tokenValue) {
				t.Fatal("wrapper exposed provider token in arguments or output")
			}
		})
	}
}

func TestNonGCPSmokeRunExitCleanupLifecycle(t *testing.T) {
	t.Parallel()
	root := repositoryRoot(t)
	tests := []struct {
		name          string
		driver        string
		target        string
		applyStatus   string
		applySignal   string
		destroyStatus string
		runnerStatus  string
		wantStatus    int
		wantSweep     string
	}{
		{
			name:          "application body failure runs automatic destroy",
			driver:        "ci/cloud-smoke.sh",
			target:        "linode-wp",
			applyStatus:   "37",
			destroyStatus: "0",
			runnerStatus:  "0",
			wantStatus:    37,
		},
		{
			name:          "config body status wins when destroy and fallback fail",
			driver:        "ci/config-management-cloud-smoke.sh",
			target:        "ansible-drupal",
			applyStatus:   "37",
			destroyStatus: "42",
			runnerStatus:  "43",
			wantStatus:    37,
			wantSweep:     "linode sweep --scope config-management --target ansible-drupal --run-id 123456789",
		},
		{
			name:          "cleanup-only failure surfaces after successful body",
			driver:        "ci/cloud-smoke.sh",
			target:        "linode-wp",
			applyStatus:   "0",
			destroyStatus: "42",
			runnerStatus:  "43",
			wantStatus:    42,
			wantSweep:     "linode sweep --scope application --target linode-wp --run-id 123456789",
		},
		{
			name:          "term reaches automatic destroy",
			driver:        "ci/cloud-smoke.sh",
			target:        "linode-wp",
			applyStatus:   "0",
			applySignal:   "TERM",
			destroyStatus: "0",
			runnerStatus:  "0",
			wantStatus:    143,
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			binDirectory := t.TempDir()
			writeCloudSmokeLifecycleFakes(t, binDirectory)
			stateDirectory := t.TempDir()
			runnerLog := filepath.Join(stateDirectory, "runner.log")
			terraformLog := filepath.Join(stateDirectory, "terraform.log")

			command := exec.Command("bash", filepath.Join(root, test.driver), test.target)
			command.Env = overriddenEnvironment(map[string]string{
				"CLOUD_COMPOSE_CI_BIN":                filepath.Join(binDirectory, "cloud-compose-ci"),
				"CLOUD_COMPOSE_SMOKE_AUTO_APPROVE":    "true",
				"CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT":    "5",
				"CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT": "10",
				"CLOUD_COMPOSE_SMOKE_KEEP":            "false",
				"CLOUD_COMPOSE_SMOKE_RUN_ID":          "123456789",
				"CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS":   "false",
				"CLOUD_COMPOSE_SMOKE_WORKDIR":         filepath.Join(stateDirectory, "smoke"),
				"CLOUD_COMPOSE_SOURCE_SHA256":         strings.Repeat("0", 64),
				"DIGITALOCEAN_TOKEN":                  "do-lifecycle-secret",
				"FAKE_APPLY_SIGNAL":                   test.applySignal,
				"FAKE_APPLY_STATUS":                   test.applyStatus,
				"FAKE_DESTROY_STATUS":                 test.destroyStatus,
				"FAKE_RUNNER_LOG":                     runnerLog,
				"FAKE_RUNNER_STATUS":                  test.runnerStatus,
				"FAKE_TERRAFORM_LOG":                  terraformLog,
				"FAKE_TERRAFORM_OUTPUT":               `{"host":"127.0.0.1","ssh_port":22,"ssh_user":"tester","project_dir":"/home/cloud-compose/app","context_name":"smoke","plugin":"wordpress","environment":"test","site":"smoke","project_name":"smoke","compose_project_name":"smoke","provider":"linode"}`,
				"GITHUB_ACTIONS":                      "true",
				"LINODE_TOKEN":                        "linode-lifecycle-secret",
				"PATH":                                binDirectory + string(os.PathListSeparator) + os.Getenv("PATH"),
			})
			output, err := command.CombinedOutput()
			if got := processExitCode(t, err); got != test.wantStatus {
				t.Fatalf("wrapper status = %d; want %d, output = %s", got, test.wantStatus, output)
			}

			terraformCalls := readTestLog(t, terraformLog)
			applyIndex := strings.Index(terraformCalls, "apply\n")
			destroyIndex := strings.LastIndex(terraformCalls, "destroy\n")
			if applyIndex < 0 || destroyIndex <= applyIndex {
				t.Fatalf("automatic cleanup did not destroy after the body:\n%s", terraformCalls)
			}

			runnerCalls := readTestLog(t, runnerLog)
			if !strings.Contains(runnerCalls, "run validate --run-id 123456789\n") {
				t.Fatalf("wrapper skipped compiled run-ID validation:\n%s", runnerCalls)
			}
			if test.wantSweep == "" {
				if strings.Contains(runnerCalls, " sweep ") {
					t.Fatalf("successful Terraform destroy unexpectedly used fallback cleanup:\n%s", runnerCalls)
				}
			} else if !strings.Contains(runnerCalls, test.wantSweep+"\n") {
				t.Fatalf("failed Terraform destroy skipped compiled fallback cleanup:\n%s", runnerCalls)
			}

			for _, secret := range []string{"do-lifecycle-secret", "linode-lifecycle-secret"} {
				if strings.Contains(string(output), secret) || strings.Contains(runnerCalls, secret) || strings.Contains(terraformCalls, secret) {
					t.Fatalf("lifecycle output exposed provider token %q", secret)
				}
			}
		})
	}
}

func writeCloudSmokeLifecycleFakes(t testing.TB, directory string) {
	t.Helper()
	sshFixture, err := os.ReadFile(filepath.Join(
		repositoryRoot(t),
		"internal/contracttest/testdata/cloud-smoke-lifecycle/ssh.sh",
	))
	if err != nil {
		t.Fatalf("read lifecycle SSH fixture: %v", err)
	}
	executables := map[string]string{
		"cloud-compose-ci": `#!/usr/bin/env bash
set -euo pipefail
operation="${1:-}:${2:-}"
{
  printf '%s' "${1:-}"
  shift || true
  printf ' %s' "$@"
  printf '\n'
} >>"$FAKE_RUNNER_LOG"
if [[ "$operation" == "run:validate" ]]; then
  exit 0
fi
exit "${FAKE_RUNNER_STATUS:-0}"
`,
		"terraform": `#!/usr/bin/env bash
set -euo pipefail
command_name=""
for argument in "$@"; do
  case "$argument" in
    init|validate|apply|output|destroy)
      command_name="$argument"
      break
      ;;
  esac
done
printf '%s\n' "$command_name" >>"$FAKE_TERRAFORM_LOG"
case "$command_name" in
  init|validate)
    exit 0
    ;;
  apply)
    if [[ -n "${FAKE_APPLY_SIGNAL:-}" ]]; then
      kill -s "$FAKE_APPLY_SIGNAL" "$PPID"
      exit 0
    fi
    exit "${FAKE_APPLY_STATUS:-0}"
    ;;
  output)
    printf '%s\n' "$FAKE_TERRAFORM_OUTPUT"
    ;;
  destroy)
    exit "${FAKE_DESTROY_STATUS:-0}"
    ;;
  *)
    echo "unexpected fake terraform invocation: $*" >&2
    exit 64
    ;;
esac
`,
		"ssh-keygen": `#!/usr/bin/env bash
set -euo pipefail
path=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-f" ]]; then
    path="${2:-}"
    break
  fi
  shift
done
[[ -n "$path" ]] || exit 64
printf 'fake-private-key\n' >"$path"
printf 'ssh-ed25519 fake-public-key cloud-compose-smoke\n' >"${path}.pub"
`,
		"ssh-keyscan": `#!/usr/bin/env bash
set -euo pipefail
printf '127.0.0.1 ssh-ed25519 fake-host-key\n'
`,
		"ssh": string(sshFixture),
		"sitectl": `#!/usr/bin/env bash
set -euo pipefail
exit 0
`,
		"docker": `#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
`,
		"git": `#!/usr/bin/env bash
set -euo pipefail
printf 'fake archive'
`,
		"curl": `#!/usr/bin/env bash
echo "unexpected network client invocation: curl $*" >&2
exit 97
`,
	}
	for name, content := range executables {
		path := filepath.Join(directory, name)
		if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
			t.Fatalf("write fake executable %s: %v", name, err)
		}
	}
}

func processExitCode(t testing.TB, err error) int {
	t.Helper()
	if err == nil {
		return 0
	}
	exitError, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("run wrapper: %v", err)
	}
	return exitError.ExitCode()
}

func readTestLog(t testing.TB, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read test log %s: %v", path, err)
	}
	return string(contents)
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

func workflowJobSection(t testing.TB, workflow, job, nextJob string) string {
	t.Helper()
	startMarker := "\n  " + job + ":\n"
	endMarker := "\n  " + nextJob + ":\n"
	start := strings.Index(workflow, startMarker)
	if start < 0 {
		t.Fatalf("workflow job %q is missing", job)
	}
	start++
	endOffset := strings.Index(workflow[start:], endMarker)
	if endOffset < 0 {
		t.Fatalf("workflow job %q has no following %q boundary", job, nextJob)
	}
	return workflow[start : start+endOffset]
}
