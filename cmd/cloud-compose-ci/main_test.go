package main

import (
	"bytes"
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/libops/cloud-compose/internal/gcpcleanup"
)

type emptyGCloud struct {
	calls [][]string
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) {
	return 0, errors.New("closed output")
}

func (f *emptyGCloud) Run(_ context.Context, args ...string) ([]byte, error) {
	f.calls = append(f.calls, slices.Clone(args))
	if len(args) >= 2 && args[0] == "projects" && args[1] == "get-iam-policy" {
		return []byte(`{}`), nil
	}
	return []byte(`[]`), nil
}

func TestRunGCPSweepUsesEnvironmentOwnership(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	environment := map[string]string{
		"GCLOUD_PROJECT":             "test-project",
		"GCLOUD_REGION":              "us-east5",
		"CLOUD_COMPOSE_SMOKE_RUN_ID": "123456789",
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run(context.Background(), []string{"gcp", "sweep"}, environmentGetter(environment), &stdout, &stderr, command, gcpcleanup.NewRedactor())
	if status != 0 {
		t.Fatalf("run() status = %d, stderr = %s", status, stderr.String())
	}

	var filter string
	for _, call := range command.calls {
		if len(call) >= 3 && slices.Equal(call[:3], []string{"compute", "instances", "list"}) {
			for index := range call {
				if call[index] == "--filter" && index+1 < len(call) {
					filter = call[index+1]
				}
			}
			break
		}
	}
	if filter != "name~'^cc-g-wp-12345678-'" {
		t.Errorf("instance ownership filter = %q", filter)
	}
}

func TestRunGCPSweepRequiresRunID(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run(
		context.Background(),
		[]string{"gcp", "sweep", "--project", "test-project"},
		environmentGetter(nil),
		&stdout,
		&stderr,
		command,
		gcpcleanup.NewRedactor(),
	)
	if status != 2 {
		t.Errorf("run() status = %d; want 2", status)
	}
	if !strings.Contains(stderr.String(), "run-id") {
		t.Errorf("stderr omits run-id requirement: %s", stderr.String())
	}
	if len(command.calls) != 0 {
		t.Fatal("run() called gcloud without an ownership scope")
	}
}

func TestRunGCPSweepAllowsExplicitOrphanSweep(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run(
		context.Background(),
		[]string{"gcp", "sweep", "--project", "test-project", "--all-runs"},
		environmentGetter(nil),
		&stdout,
		&stderr,
		command,
		gcpcleanup.NewRedactor(),
	)
	if status != 0 {
		t.Fatalf("run() status = %d, stderr = %s", status, stderr.String())
	}
}

func TestRunGCPSweepAllRunsOverridesInheritedRunID(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	environment := map[string]string{
		"CLOUD_COMPOSE_SMOKE_RUN_ID": "123456789",
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run(
		context.Background(),
		[]string{"gcp", "sweep", "--project", "test-project", "--all-runs"},
		environmentGetter(environment),
		&stdout,
		&stderr,
		command,
		gcpcleanup.NewRedactor(),
	)
	if status != 0 {
		t.Fatalf("run() status = %d, stderr = %s", status, stderr.String())
	}

	instanceList := firstCommandCall(t, command.calls, "compute", "instances", "list")
	if got := commandArgumentValue(t, instanceList, "--filter"); got != "name~'^cc-g-wp-'" {
		t.Errorf("instance ownership filter = %q; want an all-run target filter", got)
	}
}

func TestRunGCPSweepRejectsExplicitRunIDWithAllRuns(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run(
		context.Background(),
		[]string{"gcp", "sweep", "--project", "test-project", "--run-id", "123456789", "--all-runs"},
		environmentGetter(nil),
		&stdout,
		&stderr,
		command,
		gcpcleanup.NewRedactor(),
	)
	if status != 2 {
		t.Errorf("run() status = %d; want 2", status)
	}
	if !strings.Contains(stderr.String(), "mutually exclusive") {
		t.Errorf("stderr omits explicit ownership conflict: %s", stderr.String())
	}
	if len(command.calls) != 0 {
		t.Fatal("run() called gcloud with conflicting ownership flags")
	}
}

func TestRunGCPNamespaceWritesOnlyNamespaceToStdout(t *testing.T) {
	t.Parallel()
	command := &emptyGCloud{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	status := run(
		context.Background(),
		[]string{"gcp", "namespace", "--run-id", "123456789"},
		environmentGetter(nil),
		&stdout,
		&stderr,
		command,
		gcpcleanup.NewRedactor(),
	)
	if status != 0 {
		t.Fatalf("run() status = %d, stderr = %s", status, stderr.String())
	}
	if got := stdout.String(); got != "00021i3v9\n" {
		t.Errorf("stdout = %q; want namespace only", got)
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q; want empty", stderr.String())
	}
	if len(command.calls) != 0 {
		t.Fatal("namespace encoding unexpectedly called gcloud")
	}
}

func TestRunGCPNamespaceRejectsInvalidRunIDs(t *testing.T) {
	t.Parallel()
	for _, runID := range []string{"", "0123456789", "contract-run", "17592186044416"} {
		runID := runID
		t.Run(runID, func(t *testing.T) {
			t.Parallel()
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			status := run(
				context.Background(),
				[]string{"gcp", "namespace", "--run-id", runID},
				environmentGetter(nil),
				&stdout,
				&stderr,
				&emptyGCloud{},
				gcpcleanup.NewRedactor(),
			)
			if status != 2 {
				t.Errorf("run() status = %d; want 2", status)
			}
			if stdout.Len() != 0 {
				t.Errorf("stdout = %q; want empty", stdout.String())
			}
			if !strings.Contains(stderr.String(), "invalid --run-id") {
				t.Errorf("stderr omits invalid run ID error: %s", stderr.String())
			}
		})
	}
}

func TestRunGCPNamespaceReportsOutputFailure(t *testing.T) {
	t.Parallel()
	var stderr bytes.Buffer
	status := run(
		context.Background(),
		[]string{"gcp", "namespace", "--run-id", "123456789"},
		environmentGetter(nil),
		failingWriter{},
		&stderr,
		&emptyGCloud{},
		gcpcleanup.NewRedactor(),
	)
	if status != 1 {
		t.Errorf("run() status = %d; want 1", status)
	}
	if !strings.Contains(stderr.String(), "write namespace") {
		t.Errorf("stderr omits output failure: %s", stderr.String())
	}
}

func firstCommandCall(t testing.TB, calls [][]string, prefix ...string) []string {
	t.Helper()
	for _, call := range calls {
		if len(call) >= len(prefix) && slices.Equal(call[:len(prefix)], prefix) {
			return call
		}
	}
	t.Fatalf("command prefix %q was not called", prefix)
	return nil
}

func commandArgumentValue(t testing.TB, args []string, name string) string {
	t.Helper()
	for index := range args {
		if args[index] == name && index+1 < len(args) {
			return args[index+1]
		}
	}
	t.Fatalf("argument %q missing from %q", name, args)
	return ""
}

func environmentGetter(values map[string]string) func(string) string {
	return func(name string) string {
		return values[name]
	}
}
