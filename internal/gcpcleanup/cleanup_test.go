package gcpcleanup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/libops/cloud-compose/internal/runnamespace"
)

const (
	testProject        = "test-project"
	testName           = "cc-g-wp-12345678-abcd"
	testExactNamespace = "00021i3v9"
	testExactName      = "cc-g-wp-00021i3v9-abc"
)

type fakeGCloud struct {
	t      *testing.T
	mode   string
	calls  [][]string
	counts map[string]int
	done   map[string]bool
	exact  bool
}

func newFakeGCloud(t *testing.T, mode string) *fakeGCloud {
	t.Helper()
	return &fakeGCloud{
		t:      t,
		mode:   mode,
		counts: make(map[string]int),
		done:   make(map[string]bool),
	}
}

func (f *fakeGCloud) Run(_ context.Context, args ...string) ([]byte, error) {
	f.calls = append(f.calls, slices.Clone(args))
	if filter := argumentValueRaw(args, "--filter"); filter != "" {
		exactFilter := strings.Contains(filter, testExactNamespace)
		if exactFilter != f.exact {
			return []byte(`[]`), nil
		}
	}
	ownedName := f.ownedName()

	switch {
	case hasPrefix(args, "run", "services", "list"):
		f.counts["run-list"]++
		if f.mode == "retry-discovery" && f.counts["run-list"] == 1 {
			return nil, errors.New("transient list failure")
		}
		if f.mode == "secret-list-failure" {
			return nil, errors.New("authorization failed for top-secret-token")
		}
		if f.mode == "residual-cloud-run" || !f.done["run-delete"] {
			service := cloudRunService{}
			service.Metadata.Name = ownedName
			return marshalJSON(f.t, []cloudRunService{service}), nil
		}
		return marshalJSON(f.t, []cloudRunService{}), nil
	case hasPrefix(args, "run", "services", "get-iam-policy"):
		bindings := []iamBinding{{
			Role:      "roles/run.invoker",
			Members:   []string{"allUsers"},
			Condition: json.RawMessage(`{"title":"conditional"}`),
		}}
		if !f.done["run-invoker-remove"] {
			bindings = append(bindings, iamBinding{Role: "roles/run.invoker", Members: []string{"allUsers"}})
		}
		return marshalJSON(f.t, map[string]any{"bindings": bindings}), nil
	case hasPrefix(args, "compute", "instances", "list"):
		if f.mode == "out-of-scope-instance" {
			return marshalJSON(f.t, []zonalResource{{Name: "production-instance", Zone: "us-east5-b"}}), nil
		}
		if !f.done["instances-delete"] {
			return marshalJSON(f.t, []zonalResource{{Name: ownedName, Zone: "https://www.googleapis.com/compute/v1/projects/test-project/zones/us-east5-b"}}), nil
		}
		return marshalJSON(f.t, []zonalResource{}), nil
	case hasPrefix(args, "compute", "firewall-rules", "list"):
		if !f.done["firewalls-delete"] {
			return marshalJSON(f.t, []namedResource{
				{Name: "allow-ssh-ipv4-" + ownedName},
				{Name: "allow-cloud-run-" + ownedName},
			}), nil
		}
		return marshalJSON(f.t, []namedResource{}), nil
	case hasPrefix(args, "compute", "disks", "list"):
		if !f.done["disks-delete"] {
			return marshalJSON(f.t, []zonalResource{{Name: ownedName + "-data-disk", Zone: "us-east5-b"}}), nil
		}
		return marshalJSON(f.t, []zonalResource{}), nil
	case hasPrefix(args, "iam", "service-accounts", "list"):
		if !f.done["service-accounts-delete"] {
			return marshalJSON(f.t, []serviceAccount{
				{Email: "vm-" + ownedName + "@test-project.iam.gserviceaccount.com"},
				{Email: "internal-" + ownedName + "@test-project.iam.gserviceaccount.com"},
				{Email: "ppb-" + ownedName + "@test-project.iam.gserviceaccount.com"},
				{Email: ownedName + "@test-project.iam.gserviceaccount.com"},
			}), nil
		}
		return marshalJSON(f.t, []serviceAccount{}), nil
	case hasPrefix(args, "compute", "networks", "subnets", "list"):
		if !f.done["subnets-delete"] {
			return marshalJSON(f.t, []regionalResource{{Name: ownedName, Region: "https://www.googleapis.com/compute/v1/projects/test-project/regions/us-east5"}}), nil
		}
		return marshalJSON(f.t, []regionalResource{}), nil
	case hasPrefix(args, "compute", "networks", "list"):
		if !f.done["networks-delete"] {
			return marshalJSON(f.t, []namedResource{{Name: ownedName}}), nil
		}
		return marshalJSON(f.t, []namedResource{}), nil
	case hasPrefix(args, "projects", "get-iam-policy"):
		return f.projectPolicy(), nil
	}

	key, ok := mutationKey(args)
	if !ok {
		f.t.Fatalf("unexpected gcloud invocation: %q", args)
	}
	f.counts[key]++
	count := f.counts[key]
	if f.mode == "retry-transient" && count == 1 && (key == "run-delete" || key == "iam-log-remove" || key == "networks-delete") {
		return nil, errors.New("transient provider failure")
	}
	if f.mode == "aggregate-failure" && (key == "run-delete" || key == "instances-delete" || key == "subnets-delete") {
		return nil, errors.New("permanent provider failure")
	}
	if f.mode == "network-retention" && key == "subnets-delete" && count < 5 {
		return nil, errors.New("subnetwork is still reserved by serverless")
	}
	f.done[key] = true
	return nil, nil
}

func (f *fakeGCloud) ownedName() string {
	if f.exact {
		return testExactName
	}
	return testName
}

func (f *fakeGCloud) projectPolicy() []byte {
	ownedName := f.ownedName()
	bindings := make([]iamBinding, 0, 7)
	for _, entry := range []struct {
		key    string
		role   string
		member string
	}{
		{"iam-log-remove", "roles/logging.logWriter", "serviceAccount:vm-" + ownedName + "@test-project.iam.gserviceaccount.com"},
		{"iam-monitoring-remove", "roles/monitoring.metricWriter", "serviceAccount:internal-" + ownedName + "@test-project.iam.gserviceaccount.com"},
		{"iam-suspend-remove", "projects/test-project/roles/suspendVM", "serviceAccount:internal-" + ownedName + "@test-project.iam.gserviceaccount.com"},
		{"iam-start-remove", "projects/test-project/roles/startVM", "serviceAccount:ppb-" + ownedName + "@test-project.iam.gserviceaccount.com"},
	} {
		if !f.done[entry.key] {
			bindings = append(bindings, iamBinding{Role: entry.role, Members: []string{entry.member}})
		}
	}
	bindings = append(bindings,
		iamBinding{
			Role:      "roles/logging.logWriter",
			Members:   []string{"serviceAccount:vm-" + ownedName + "@test-project.iam.gserviceaccount.com"},
			Condition: json.RawMessage(`{"title":"keep-conditional"}`),
		},
		iamBinding{Role: "roles/owner", Members: []string{"serviceAccount:" + ownedName + "@test-project.iam.gserviceaccount.com"}},
		iamBinding{Role: "roles/logging.logWriter", Members: []string{"serviceAccount:production@test-project.iam.gserviceaccount.com"}},
	)
	return marshalJSON(f.t, map[string]any{"bindings": bindings})
}

func TestSweepRetriesAndCoversOwnedResources(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "retry-transient")
	runner, sleeps := testRunner(fake, nil)

	if err := runner.Sweep(context.Background(), testConfig()); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}

	for key, expected := range map[string]int{
		"run-invoker-remove":      1,
		"run-delete":              2,
		"instances-delete":        1,
		"firewalls-delete":        2,
		"disks-delete":            1,
		"iam-log-remove":          2,
		"iam-monitoring-remove":   1,
		"iam-suspend-remove":      1,
		"iam-start-remove":        1,
		"service-accounts-delete": 4,
		"subnets-delete":          1,
		"networks-delete":         2,
	} {
		if actual := fake.counts[key]; actual != expected {
			t.Errorf("mutation %s count = %d; want %d", key, actual, expected)
		}
	}
	if *sleeps != 3 {
		t.Errorf("retry sleep count = %d; want 3", *sleeps)
	}

	instanceList := firstCall(t, fake.calls, "compute", "instances", "list")
	if got := argumentValue(t, instanceList, "--filter"); got != "name~'^cc-g-wp-12345678-'" {
		t.Errorf("instance filter = %q", got)
	}
	if !hasFilterContaining(fake.calls, testExactNamespace) {
		t.Fatal("cleanup did not query the reserved exact run namespace")
	}
	serviceAccountList := firstCall(t, fake.calls, "iam", "service-accounts", "list")
	if got := argumentValue(t, serviceAccountList, "--filter"); !strings.Contains(got, "ppb-") {
		t.Errorf("service-account filter omits power-button identity: %q", got)
	}
	firewallList := firstCall(t, fake.calls, "compute", "firewall-rules", "list")
	if got := argumentValue(t, firewallList, "--filter"); !strings.Contains(got, "allow-cloud-run-") {
		t.Errorf("firewall filter omits Direct VPC ingress rule: %q", got)
	}

	invokerIndex := firstCallIndex(t, fake.calls, "run", "services", "remove-iam-policy-binding")
	runDeleteIndex := firstCallIndex(t, fake.calls, "run", "services", "delete")
	instanceIndex := firstCallIndex(t, fake.calls, "compute", "instances", "delete")
	if !(invokerIndex < runDeleteIndex && runDeleteIndex < instanceIndex) {
		t.Errorf("Cloud Run ingress/service/instance cleanup order = %d, %d, %d", invokerIndex, runDeleteIndex, instanceIndex)
	}
	iamIndex := lastCallIndex(t, fake.calls, "projects", "remove-iam-policy-binding")
	accountIndex := firstCallIndex(t, fake.calls, "iam", "service-accounts", "delete")
	if iamIndex >= accountIndex {
		t.Errorf("project IAM removal index %d is not before service-account deletion %d", iamIndex, accountIndex)
	}
	subnetIndex := lastCallIndex(t, fake.calls, "compute", "networks", "subnets", "delete")
	networkIndex := firstCallIndex(t, fake.calls, "compute", "networks", "delete")
	if subnetIndex >= networkIndex {
		t.Errorf("subnetwork deletion index %d is not before network deletion %d", subnetIndex, networkIndex)
	}

	for _, call := range matchingCalls(fake.calls, "projects", "remove-iam-policy-binding") {
		if !slices.Contains(call, "--condition=None") {
			t.Errorf("project IAM removal omits --condition=None: %q", call)
		}
	}
	invokerCall := firstCall(t, fake.calls, "run", "services", "remove-iam-policy-binding")
	if !slices.Contains(invokerCall, "--condition=None") {
		t.Errorf("Cloud Run IAM removal omits --condition=None: %q", invokerCall)
	}
}

func TestSweepMutatesOrdersAndVerifiesExactNamespaceResources(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "success")
	fake.exact = true
	runner, _ := testRunner(fake, nil)

	if err := runner.Sweep(context.Background(), testConfig()); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}

	for key, expected := range map[string]int{
		"run-invoker-remove":      1,
		"run-delete":              1,
		"instances-delete":        1,
		"firewalls-delete":        2,
		"disks-delete":            1,
		"iam-log-remove":          1,
		"iam-monitoring-remove":   1,
		"iam-suspend-remove":      1,
		"iam-start-remove":        1,
		"service-accounts-delete": 4,
		"subnets-delete":          1,
		"networks-delete":         1,
	} {
		if actual := fake.counts[key]; actual != expected {
			t.Errorf("exact-namespace mutation %s count = %d; want %d", key, actual, expected)
		}
	}
	if actual := fake.counts["run-list"]; actual != 2 {
		t.Errorf("exact-namespace Cloud Run list count = %d; want initial discovery plus residual verification", actual)
	}

	for _, prefix := range [][]string{
		{"run", "services", "delete"},
		{"compute", "instances", "delete"},
		{"compute", "disks", "delete"},
		{"compute", "networks", "subnets", "delete"},
		{"compute", "networks", "delete"},
	} {
		call := firstCall(t, fake.calls, prefix...)
		if !strings.Contains(strings.Join(call, "\x00"), testExactName) {
			t.Errorf("exact-namespace mutation %q does not own %q: %q", prefix, testExactName, call)
		}
	}

	invokerIndex := firstCallIndex(t, fake.calls, "run", "services", "remove-iam-policy-binding")
	runDeleteIndex := firstCallIndex(t, fake.calls, "run", "services", "delete")
	instanceIndex := firstCallIndex(t, fake.calls, "compute", "instances", "delete")
	if !(invokerIndex < runDeleteIndex && runDeleteIndex < instanceIndex) {
		t.Errorf("exact Cloud Run ingress/service/instance cleanup order = %d, %d, %d", invokerIndex, runDeleteIndex, instanceIndex)
	}
	iamIndex := lastCallIndex(t, fake.calls, "projects", "remove-iam-policy-binding")
	accountIndex := firstCallIndex(t, fake.calls, "iam", "service-accounts", "delete")
	if iamIndex >= accountIndex {
		t.Errorf("exact project IAM removal index %d is not before service-account deletion %d", iamIndex, accountIndex)
	}
	subnetIndex := lastCallIndex(t, fake.calls, "compute", "networks", "subnets", "delete")
	networkIndex := firstCallIndex(t, fake.calls, "compute", "networks", "delete")
	if subnetIndex >= networkIndex {
		t.Errorf("exact subnetwork deletion index %d is not before network deletion %d", subnetIndex, networkIndex)
	}
}

func TestSweepReportsExactNamespaceResiduals(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "residual-cloud-run")
	fake.exact = true
	runner, _ := testRunner(fake, nil)

	err := runner.Sweep(context.Background(), testConfig())
	if err == nil || !strings.Contains(err.Error(), "verify residual resources") {
		t.Fatalf("Sweep() error = %v; want exact-namespace residual failure", err)
	}
	if actual := fake.counts["run-list"]; actual != defaultAttempts+1 {
		t.Errorf("exact-namespace Cloud Run list count = %d; want %d", actual, defaultAttempts+1)
	}
}

func TestSweepAggregatesPermanentFailures(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "aggregate-failure")
	runner, _ := testRunner(fake, nil)

	err := runner.Sweep(context.Background(), testConfig())
	if err == nil {
		t.Fatal("Sweep() unexpectedly succeeded")
	}
	for _, key := range []string{"run-delete", "instances-delete"} {
		if actual := fake.counts[key]; actual != defaultAttempts {
			t.Errorf("mutation %s count = %d; want %d", key, actual, defaultAttempts)
		}
	}
	if actual := fake.counts["subnets-delete"]; actual < 2 {
		t.Errorf("subnetwork mutation count = %d; want a bounded network-retention retry", actual)
	}
	for _, key := range []string{"networks-delete", "service-accounts-delete"} {
		if fake.counts[key] == 0 {
			t.Errorf("cleanup stopped before unrelated mutation %s", key)
		}
	}
	message := err.Error()
	for _, expected := range []string{"Cloud Run service", "instance", "subnetwork", "verify residual resources"} {
		if !strings.Contains(message, expected) {
			t.Errorf("aggregate error omits %q: %s", expected, message)
		}
	}
}

func TestSweepRetriesTransientDiscovery(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "retry-discovery")
	runner, sleeps := testRunner(fake, nil)

	if err := runner.Sweep(context.Background(), testConfig()); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if actual := fake.counts["run-list"]; actual != 3 {
		t.Errorf("Cloud Run list count = %d; want initial retry plus final verification", actual)
	}
	if *sleeps != 1 {
		t.Errorf("query retry sleep count = %d; want 1", *sleeps)
	}
}

func TestSweepUsesSharedDirectVPCReleaseWindow(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "network-retention")
	runner, sleeps := testRunner(fake, nil)

	if err := runner.Sweep(context.Background(), testConfig()); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if actual := fake.counts["subnets-delete"]; actual != 5 {
		t.Errorf("subnetwork mutation count = %d; want 5", actual)
	}
	if *sleeps != 4 {
		t.Errorf("network retention sleep count = %d; want 4", *sleeps)
	}
}

func TestSweepExhaustsResidualVerification(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "residual-cloud-run")
	runner, _ := testRunner(fake, nil)

	if err := runner.Sweep(context.Background(), testConfig()); err == nil {
		t.Fatal("Sweep() unexpectedly succeeded with a residual Cloud Run service")
	}
	if actual := fake.counts["run-list"]; actual != defaultAttempts+1 {
		t.Errorf("Cloud Run list count = %d; want %d", actual, defaultAttempts+1)
	}
}

func TestSweepRejectsOutOfScopeListResults(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "out-of-scope-instance")
	runner, _ := testRunner(fake, nil)

	err := runner.Sweep(context.Background(), testConfig())
	if err == nil || !strings.Contains(err.Error(), "out-of-scope") {
		t.Fatalf("Sweep() error = %v; want out-of-scope failure", err)
	}
	if fake.counts["instances-delete"] != 0 {
		t.Fatal("cleanup deleted an out-of-scope instance")
	}
}

func TestSweepRedactsCommandFailures(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "secret-list-failure")
	var logs bytes.Buffer
	redactor := NewRedactor("top-secret-token")
	runner, _ := testRunner(fake, &logs)
	runner.Redactor = redactor

	err := runner.Sweep(context.Background(), testConfig())
	if err == nil {
		t.Fatal("Sweep() unexpectedly succeeded")
	}
	combined := logs.String() + err.Error()
	if strings.Contains(combined, "top-secret-token") {
		t.Fatalf("cleanup output leaked a configured secret: %s", combined)
	}
	if !strings.Contains(combined, "[REDACTED]") {
		t.Fatalf("cleanup output did not mark redacted data: %s", combined)
	}
}

func TestNameFilterMatchesTerraformOwnership(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name   string
		target string
		runID  string
		want   string
	}{
		{name: "workflow run", target: "gcp-wp", runID: "123456789", want: "^cc-g-wp-12345678-"},
		{name: "normalized", target: "gcp-omeka-s", runID: "AB_cd!234567", want: "^cc-g-os-ab-cd-23-"},
		{name: "all runs", target: "gcp-wp", want: "^cc-g-wp-"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := NameFilter(test.target, test.runID)
			if err != nil {
				t.Fatalf("NameFilter() error = %v", err)
			}
			if got != test.want {
				t.Errorf("NameFilter() = %q; want %q", got, test.want)
			}
		})
	}
}

func TestOwnershipFiltersReserveExactRunNamespace(t *testing.T) {
	t.Parallel()
	filters, err := ownershipFilters("gcp-wp", "123456789")
	if err != nil {
		t.Fatalf("ownershipFilters() error = %v", err)
	}
	want := []string{
		"^cc-g-wp-12345678-",
		"^cc-g-wp-" + testExactNamespace + "-",
	}
	if !slices.Equal(filters, want) {
		t.Errorf("ownershipFilters() = %q; want %q", filters, want)
	}

	left, _ := ownershipFilters("gcp-wp", "123456780")
	right, _ := ownershipFilters("gcp-wp", "123456789")
	if left[0] != right[0] {
		t.Fatal("test inputs no longer demonstrate the legacy eight-character collision")
	}
	if left[1] == right[1] {
		t.Fatal("exact run namespaces collide")
	}
}

func TestExactOwnershipFilterFitsEverySupportedGCPTarget(t *testing.T) {
	t.Parallel()
	const (
		runID          = "123456789"
		otherRunID     = "123456780"
		resourceSuffix = "a"
		gcpNameLimit   = 21
	)
	targets := []struct {
		target string
		prefix string
	}{
		{target: "gcp-archivesspace", prefix: "cc-g-as"},
		{target: "gcp-ojs", prefix: "cc-g-ojs"},
		{target: "gcp-isle", prefix: "cc-g-isle"},
		{target: "gcp-drupal", prefix: "cc-g-dr"},
		{target: "gcp-wp", prefix: "cc-g-wp"},
		{target: "gcp-omeka-s", prefix: "cc-g-os"},
		{target: "gcp-omeka-classic", prefix: "cc-g-oc"},
	}

	otherNamespace, err := runnamespace.Encode(otherRunID)
	if err != nil {
		t.Fatalf("runnamespace.Encode(%q) error = %v", otherRunID, err)
	}
	for _, test := range targets {
		t.Run(test.target, func(t *testing.T) {
			prefix, err := targetNamePrefix(test.target)
			if err != nil {
				t.Fatalf("targetNamePrefix() error = %v", err)
			}
			if prefix != test.prefix {
				t.Fatalf("targetNamePrefix() = %q; want %q", prefix, test.prefix)
			}

			filters, err := ownershipFilters(test.target, runID)
			if err != nil {
				t.Fatalf("ownershipFilters() error = %v", err)
			}
			if len(filters) != 2 {
				t.Fatalf("ownershipFilters() returned %d filters; want legacy and exact", len(filters))
			}

			resourceName := strings.Join([]string{prefix, testExactNamespace, resourceSuffix}, "-")
			if len(resourceName) > gcpNameLimit {
				t.Fatalf("exact resource name %q is %d characters; limit is %d", resourceName, len(resourceName), gcpNameLimit)
			}
			if !strings.HasSuffix(resourceName, "-"+resourceSuffix) {
				t.Fatalf("exact resource name %q lost its separator or random suffix", resourceName)
			}
			if !regexp.MustCompile(filters[1]).MatchString(resourceName) {
				t.Fatalf("exact filter %q does not match resource %q", filters[1], resourceName)
			}

			otherResource := strings.Join([]string{prefix, otherNamespace, resourceSuffix}, "-")
			if regexp.MustCompile(filters[1]).MatchString(otherResource) {
				t.Fatalf("exact filter %q matched another run's resource %q", filters[1], otherResource)
			}
		})
	}
}

func TestSweepRequiresExplicitAllRunOwnership(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "success")
	runner, _ := testRunner(fake, nil)
	config := testConfig()
	config.RunID = ""

	err := runner.Sweep(context.Background(), config)
	if err == nil || !strings.Contains(err.Error(), "run id is required") {
		t.Fatalf("Sweep() error = %v; want missing run-id error", err)
	}
	if len(fake.calls) != 0 {
		t.Fatal("cleanup called gcloud before establishing resource ownership")
	}
}

func TestSweepRejectsConflictingOwnershipScopes(t *testing.T) {
	t.Parallel()
	fake := newFakeGCloud(t, "success")
	runner, _ := testRunner(fake, nil)
	config := testConfig()
	config.AllowAllRuns = true

	err := runner.Sweep(context.Background(), config)
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("Sweep() error = %v; want conflicting ownership error", err)
	}
	if len(fake.calls) != 0 {
		t.Fatal("cleanup called gcloud before rejecting conflicting ownership scopes")
	}
}

func TestSweepRejectsInvalidRunIDBeforeCommand(t *testing.T) {
	t.Parallel()
	for _, runID := range []string{
		"12345678oops",
		"012345678",
		"17592186044416",
	} {
		t.Run(runID, func(t *testing.T) {
			fake := newFakeGCloud(t, "success")
			runner, _ := testRunner(fake, nil)
			config := testConfig()
			config.RunID = runID

			err := runner.Sweep(context.Background(), config)
			if err == nil || !strings.Contains(err.Error(), "canonical decimal value no larger than 44 bits") {
				t.Fatalf("Sweep() error = %v; want invalid run-id error", err)
			}
			if len(fake.calls) != 0 {
				t.Fatalf("cleanup called gcloud before rejecting invalid run ID %q: %q", runID, fake.calls)
			}
		})
	}
}

func testRunner(command Commander, logs *bytes.Buffer) (Runner, *int) {
	sleeps := 0
	var logger *slog.Logger
	if logs == nil {
		logger = slog.New(slog.NewTextHandler(ioDiscard{}, nil))
	} else {
		logger = slog.New(slog.NewTextHandler(logs, nil))
	}
	return Runner{
		Command: command,
		Logger:  logger,
		Sleep: func(context.Context, time.Duration) error {
			sleeps++
			return nil
		},
	}, &sleeps
}

type ioDiscard struct{}

func (ioDiscard) Write(data []byte) (int, error) {
	return len(data), nil
}

func testConfig() Config {
	return Config{
		Project:            testProject,
		Region:             "us-east5",
		Target:             "gcp-wp",
		RunID:              "123456789",
		Attempts:           defaultAttempts,
		RetryDelay:         time.Nanosecond,
		QueryAttempts:      defaultQueryAttempts,
		QueryRetryDelay:    time.Nanosecond,
		NetworkRetryWindow: 15 * time.Nanosecond,
	}
}

func marshalJSON(t *testing.T, value any) []byte {
	t.Helper()
	result, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal fake gcloud response: %v", err)
	}
	return result
}

func mutationKey(args []string) (string, bool) {
	switch {
	case hasPrefix(args, "run", "services", "remove-iam-policy-binding"):
		return "run-invoker-remove", true
	case hasPrefix(args, "run", "services", "delete"):
		return "run-delete", true
	case hasPrefix(args, "compute", "instances", "delete"):
		return "instances-delete", true
	case hasPrefix(args, "compute", "firewall-rules", "delete"):
		return "firewalls-delete", true
	case hasPrefix(args, "compute", "disks", "delete"):
		return "disks-delete", true
	case hasPrefix(args, "iam", "service-accounts", "delete"):
		return "service-accounts-delete", true
	case hasPrefix(args, "compute", "networks", "subnets", "delete"):
		return "subnets-delete", true
	case hasPrefix(args, "compute", "networks", "delete"):
		return "networks-delete", true
	case hasPrefix(args, "projects", "remove-iam-policy-binding"):
		switch argumentValueRaw(args, "--role") {
		case "roles/logging.logWriter":
			return "iam-log-remove", true
		case "roles/monitoring.metricWriter":
			return "iam-monitoring-remove", true
		case "projects/test-project/roles/suspendVM":
			return "iam-suspend-remove", true
		case "projects/test-project/roles/startVM":
			return "iam-start-remove", true
		}
	}
	return "", false
}

func hasPrefix(args []string, prefix ...string) bool {
	return len(args) >= len(prefix) && slices.Equal(args[:len(prefix)], prefix)
}

func firstCall(t *testing.T, calls [][]string, prefix ...string) []string {
	t.Helper()
	index := firstCallIndex(t, calls, prefix...)
	return calls[index]
}

func firstCallIndex(t *testing.T, calls [][]string, prefix ...string) int {
	t.Helper()
	for index, call := range calls {
		if hasPrefix(call, prefix...) {
			return index
		}
	}
	t.Fatalf("call %q not found", prefix)
	return -1
}

func lastCallIndex(t *testing.T, calls [][]string, prefix ...string) int {
	t.Helper()
	for index := len(calls) - 1; index >= 0; index-- {
		if hasPrefix(calls[index], prefix...) {
			return index
		}
	}
	t.Fatalf("call %q not found", prefix)
	return -1
}

func matchingCalls(calls [][]string, prefix ...string) [][]string {
	result := make([][]string, 0)
	for _, call := range calls {
		if hasPrefix(call, prefix...) {
			result = append(result, call)
		}
	}
	return result
}

func argumentValue(t *testing.T, args []string, name string) string {
	t.Helper()
	value := argumentValueRaw(args, name)
	if value == "" {
		t.Fatalf("argument %s not found in %q", name, args)
	}
	return value
}

func argumentValueRaw(args []string, name string) string {
	for index := 0; index+1 < len(args); index++ {
		if args[index] == name {
			return args[index+1]
		}
	}
	return ""
}

func hasFilterContaining(calls [][]string, fragment string) bool {
	for _, call := range calls {
		if strings.Contains(argumentValueRaw(call, "--filter"), fragment) {
			return true
		}
	}
	return false
}

func ExampleNameFilter() {
	filter, _ := NameFilter("gcp-wp", "123456789")
	fmt.Println(filter)
	// Output: ^cc-g-wp-12345678-
}
