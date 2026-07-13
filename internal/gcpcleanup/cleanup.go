package gcpcleanup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"github.com/libops/cloud-compose/internal/runnamespace"
)

const (
	defaultAttempts           = 12
	defaultDelay              = 10 * time.Second
	defaultQueryAttempts      = 3
	defaultQueryDelay         = 2 * time.Second
	defaultNetworkRetryWindow = 2*time.Hour + 10*time.Minute
)

var templateSlugs = map[string]string{
	"archivesspace": "as",
	"drupal":        "dr",
	"isle":          "isle",
	"ojs":           "ojs",
	"omeka-classic": "oc",
	"omeka-s":       "os",
	"wp":            "wp",
}

// Config identifies the GCP smoke resources that one sweep owns.
type Config struct {
	Project            string
	Region             string
	Target             string
	RunID              string
	Attempts           int
	RetryDelay         time.Duration
	QueryAttempts      int
	QueryRetryDelay    time.Duration
	NetworkRetryWindow time.Duration
	AllowAllRuns       bool
}

// Runner performs ordered GCP smoke-resource cleanup.
type Runner struct {
	Command            Commander
	Logger             *slog.Logger
	Redactor           *Redactor
	Sleep              func(context.Context, time.Duration) error
	queryAttempts      int
	queryRetryDelay    time.Duration
	networkRetryBudget *time.Duration
}

type namedResource struct {
	Name string `json:"name"`
}

type zonalResource struct {
	Name string `json:"name"`
	Zone string `json:"zone"`
}

type regionalResource struct {
	Name   string `json:"name"`
	Region string `json:"region"`
}

type serviceAccount struct {
	Email string `json:"email"`
}

type cloudRunService struct {
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
}

type iamBinding struct {
	Role      string          `json:"role"`
	Members   []string        `json:"members"`
	Condition json.RawMessage `json:"condition,omitempty"`
}

type projectIAMBinding struct {
	Role   string
	Member string
}

type residual struct {
	Kind   string
	Name   string
	Role   string
	Member string
}

type failureList struct {
	errors []error
}

// NameFilter returns the legacy anchored resource-name filter retained for
// compatibility with smoke resources created before exact namespaces.
func NameFilter(target, runID string) (string, error) {
	prefix, err := targetNamePrefix(target)
	if err != nil {
		return "", err
	}
	filter := "^" + prefix + "-"
	if runID != "" {
		filter += normalizeRunID(runID, 8) + "-"
	}
	return filter, nil
}

func ownershipFilters(target, runID string) ([]string, error) {
	legacy, err := NameFilter(target, runID)
	if err != nil {
		return nil, err
	}
	if runID == "" {
		return []string{legacy}, nil
	}
	prefix, err := targetNamePrefix(target)
	if err != nil {
		return nil, err
	}
	namespace, err := runnamespace.Encode(runID)
	if err != nil {
		return nil, fmt.Errorf("encode run ID namespace: %w", err)
	}
	return []string{legacy, "^" + prefix + "-" + namespace + "-"}, nil
}

// Sweep removes all disposable GCP resources selected by the configuration.
func (r Runner) Sweep(ctx context.Context, config Config) error {
	config, err := normalizeConfig(config)
	if err != nil {
		return err
	}
	if r.Command == nil {
		return errors.New("gcp cleanup command is required")
	}
	if config.RunID == "" && !config.AllowAllRuns {
		return errors.New("run id is required unless all-run cleanup is explicitly enabled")
	}
	if config.RunID != "" && config.AllowAllRuns {
		return errors.New("run id and all-run cleanup are mutually exclusive")
	}

	redactor := r.Redactor
	if redactor == nil {
		redactor = NewRedactor()
	}
	logger := r.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	sleep := r.Sleep
	if sleep == nil {
		sleep = sleepContext
	}
	r.Redactor = redactor
	r.Logger = logger
	r.Sleep = sleep
	r.queryAttempts = config.QueryAttempts
	r.queryRetryDelay = config.QueryRetryDelay
	networkRetryBudget := config.NetworkRetryWindow
	r.networkRetryBudget = &networkRetryBudget

	nameFilters, err := ownershipFilters(config.Target, config.RunID)
	if err != nil {
		return err
	}
	failures := &failureList{}

	for _, nameFilter := range nameFilters {
		ownedNames := regexp.MustCompile(nameFilter)
		r.cleanupCloudRun(ctx, config, nameFilter, ownedNames, failures)
		r.cleanupInstances(ctx, config, nameFilter, ownedNames, failures)
		r.cleanupFirewalls(ctx, config, nameFilter, failures)
		r.cleanupDisks(ctx, config, nameFilter, ownedNames, failures)
		r.cleanupProjectIAM(ctx, config, nameFilter, failures)
		r.cleanupServiceAccounts(ctx, config, nameFilter, failures)
		r.cleanupSubnetworks(ctx, config, nameFilter, ownedNames, failures)
		r.cleanupNetworks(ctx, config, nameFilter, ownedNames, failures)
	}

	for _, nameFilter := range nameFilters {
		if err := r.verifyNoResources(ctx, config, nameFilter); err != nil {
			failures.add("verify residual resources for "+nameFilter, err, redactor)
		}
	}
	if failures.empty() {
		logger.Info("GCP smoke cleanup completed", "target", config.Target, "run_id", normalizeRunID(config.RunID, 8))
		return nil
	}
	return failures
}

func (r Runner) cleanupCloudRun(ctx context.Context, config Config, nameFilter string, owned *regexp.Regexp, failures *failureList) {
	services, err := r.listCloudRun(ctx, config, nameFilter)
	if err != nil {
		failures.add("list Cloud Run services", err, r.Redactor)
		return
	}
	for _, service := range services {
		name := service.Metadata.Name
		if !owned.MatchString(name) {
			failures.addMessage("Cloud Run list returned out-of-scope service " + name)
			continue
		}
		policy, err := r.cloudRunPolicy(ctx, config, name)
		if err != nil {
			failures.add("inspect Cloud Run IAM policy for "+name, err, r.Redactor)
		} else if hasUnconditionalMember(policy, "roles/run.invoker", "allUsers") {
			args := []string{
				"run", "services", "remove-iam-policy-binding", name,
				"--project", config.Project,
				"--region", config.Region,
				"--member", "allUsers",
				"--role", "roles/run.invoker",
				"--condition=None",
				"--quiet",
			}
			if err := r.retry(ctx, config, "remove Cloud Run invoker from "+name, args); err != nil {
				failures.add("remove Cloud Run invoker from "+name, err, r.Redactor)
			}
		}

		args := []string{
			"run", "services", "delete", name,
			"--project", config.Project,
			"--region", config.Region,
			"--quiet",
		}
		if err := r.retry(ctx, config, "delete Cloud Run service "+name, args); err != nil {
			failures.add("delete Cloud Run service "+name, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupInstances(ctx context.Context, config Config, nameFilter string, owned *regexp.Regexp, failures *failureList) {
	resources, err := r.listZonal(ctx, "compute", "instances", config.Project, nameFilter)
	if err != nil {
		failures.add("list compute instances", err, r.Redactor)
		return
	}
	for _, resource := range resources {
		if !owned.MatchString(resource.Name) {
			failures.addMessage("instance list returned out-of-scope resource " + resource.Name)
			continue
		}
		zone, err := resourceLocation(resource.Zone)
		if err != nil {
			failures.add("resolve zone for instance "+resource.Name, err, r.Redactor)
			continue
		}
		args := []string{"compute", "instances", "delete", resource.Name, "--project", config.Project, "--zone", zone, "--quiet"}
		if err := r.retry(ctx, config, "delete instance "+resource.Name, args); err != nil {
			failures.add("delete instance "+resource.Name, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupFirewalls(ctx context.Context, config Config, nameFilter string, failures *failureList) {
	resources, err := r.listFirewalls(ctx, config, nameFilter)
	if err != nil {
		failures.add("list firewall rules", err, r.Redactor)
		return
	}
	owned := firewallPattern(nameFilter)
	for _, resource := range resources {
		if !owned.MatchString(resource.Name) {
			failures.addMessage("firewall list returned out-of-scope resource " + resource.Name)
			continue
		}
		args := []string{"compute", "firewall-rules", "delete", resource.Name, "--project", config.Project, "--quiet"}
		if err := r.retry(ctx, config, "delete firewall "+resource.Name, args); err != nil {
			failures.add("delete firewall "+resource.Name, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupDisks(ctx context.Context, config Config, nameFilter string, owned *regexp.Regexp, failures *failureList) {
	resources, err := r.listZonal(ctx, "compute", "disks", config.Project, nameFilter)
	if err != nil {
		failures.add("list compute disks", err, r.Redactor)
		return
	}
	for _, resource := range resources {
		if !owned.MatchString(resource.Name) {
			failures.addMessage("disk list returned out-of-scope resource " + resource.Name)
			continue
		}
		zone, err := resourceLocation(resource.Zone)
		if err != nil {
			failures.add("resolve zone for disk "+resource.Name, err, r.Redactor)
			continue
		}
		args := []string{"compute", "disks", "delete", resource.Name, "--project", config.Project, "--zone", zone, "--quiet"}
		if err := r.retry(ctx, config, "delete disk "+resource.Name, args); err != nil {
			failures.add("delete disk "+resource.Name, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupProjectIAM(ctx context.Context, config Config, nameFilter string, failures *failureList) {
	bindings, err := r.listProjectIAM(ctx, config.Project, nameFilter)
	if err != nil {
		failures.add("list project IAM bindings", err, r.Redactor)
		return
	}
	for _, binding := range bindings {
		args := []string{
			"projects", "remove-iam-policy-binding", config.Project,
			"--member", binding.Member,
			"--role", binding.Role,
			"--condition=None",
			"--quiet",
		}
		description := fmt.Sprintf("remove project IAM binding %s for %s", binding.Role, binding.Member)
		if err := r.retry(ctx, config, description, args); err != nil {
			failures.add(description, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupServiceAccounts(ctx context.Context, config Config, nameFilter string, failures *failureList) {
	accounts, err := r.listServiceAccounts(ctx, config, nameFilter)
	if err != nil {
		failures.add("list service accounts", err, r.Redactor)
		return
	}
	owned := serviceAccountPattern(config.Project, nameFilter)
	for _, account := range accounts {
		if !owned.MatchString("serviceAccount:" + account.Email) {
			failures.addMessage("service-account list returned out-of-scope account " + account.Email)
			continue
		}
		args := []string{"iam", "service-accounts", "delete", account.Email, "--project", config.Project, "--quiet"}
		if err := r.retry(ctx, config, "delete service account "+account.Email, args); err != nil {
			failures.add("delete service account "+account.Email, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupSubnetworks(ctx context.Context, config Config, nameFilter string, owned *regexp.Regexp, failures *failureList) {
	resources, err := r.listSubnetworks(ctx, config.Project, nameFilter)
	if err != nil {
		failures.add("list subnetworks", err, r.Redactor)
		return
	}
	for _, resource := range resources {
		if !owned.MatchString(resource.Name) {
			failures.addMessage("subnetwork list returned out-of-scope resource " + resource.Name)
			continue
		}
		region, err := resourceLocation(resource.Region)
		if err != nil {
			failures.add("resolve region for subnetwork "+resource.Name, err, r.Redactor)
			continue
		}
		args := []string{"compute", "networks", "subnets", "delete", resource.Name, "--project", config.Project, "--region", region, "--quiet"}
		if err := r.retryNetwork(ctx, config, "delete subnetwork "+resource.Name, args); err != nil {
			failures.add("delete subnetwork "+resource.Name, err, r.Redactor)
		}
	}
}

func (r Runner) cleanupNetworks(ctx context.Context, config Config, nameFilter string, owned *regexp.Regexp, failures *failureList) {
	resources, err := r.listNamed(ctx, []string{"compute", "networks", "list"}, config.Project, "name", nameFilter)
	if err != nil {
		failures.add("list networks", err, r.Redactor)
		return
	}
	for _, resource := range resources {
		if !owned.MatchString(resource.Name) {
			failures.addMessage("network list returned out-of-scope resource " + resource.Name)
			continue
		}
		args := []string{"compute", "networks", "delete", resource.Name, "--project", config.Project, "--quiet"}
		if err := r.retryNetwork(ctx, config, "delete network "+resource.Name, args); err != nil {
			failures.add("delete network "+resource.Name, err, r.Redactor)
		}
	}
}

func (r Runner) verifyNoResources(ctx context.Context, config Config, nameFilter string) error {
	var lastError error
	for attempt := 1; attempt <= config.Attempts; attempt++ {
		resources, err := r.residuals(ctx, config, nameFilter)
		if err == nil && len(resources) == 0 {
			r.Logger.Info("Verified that no matching GCP smoke resources remain")
			return nil
		}
		if err != nil {
			lastError = err
			r.Logger.Warn("Could not verify GCP residual resources", "attempt", attempt, "error", r.Redactor.String(err.Error()))
		} else {
			lastError = fmt.Errorf("%d matching resources remain", len(resources))
			for _, resource := range resources {
				r.Logger.Warn("Matching GCP smoke resource remains", "attempt", attempt, "kind", resource.Kind, "name", resource.Name, "role", resource.Role, "member", resource.Member)
			}
		}
		if attempt < config.Attempts {
			if err := r.Sleep(ctx, config.RetryDelay); err != nil {
				return fmt.Errorf("wait before residual verification retry: %w", err)
			}
		}
	}
	return fmt.Errorf("GCP smoke cleanup left matching resources or could not verify their removal: %w", lastError)
}

func (r Runner) residuals(ctx context.Context, config Config, nameFilter string) ([]residual, error) {
	result := make([]residual, 0)

	services, err := r.listCloudRun(ctx, config, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify Cloud Run services: %w", err)
	}
	for _, service := range services {
		result = append(result, residual{Kind: "cloud-run", Name: service.Metadata.Name})
	}

	instances, err := r.listZonal(ctx, "compute", "instances", config.Project, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify instances: %w", err)
	}
	for _, instance := range instances {
		result = append(result, residual{Kind: "instance", Name: instance.Name})
	}

	firewalls, err := r.listFirewalls(ctx, config, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify firewalls: %w", err)
	}
	for _, firewall := range firewalls {
		result = append(result, residual{Kind: "firewall", Name: firewall.Name})
	}

	disks, err := r.listZonal(ctx, "compute", "disks", config.Project, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify disks: %w", err)
	}
	for _, disk := range disks {
		result = append(result, residual{Kind: "disk", Name: disk.Name})
	}

	accounts, err := r.listServiceAccounts(ctx, config, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify service accounts: %w", err)
	}
	for _, account := range accounts {
		result = append(result, residual{Kind: "service-account", Name: account.Email})
	}

	subnetworks, err := r.listSubnetworks(ctx, config.Project, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify subnetworks: %w", err)
	}
	for _, subnetwork := range subnetworks {
		result = append(result, residual{Kind: "subnetwork", Name: subnetwork.Name})
	}

	networks, err := r.listNamed(ctx, []string{"compute", "networks", "list"}, config.Project, "name", nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify networks: %w", err)
	}
	for _, network := range networks {
		result = append(result, residual{Kind: "network", Name: network.Name})
	}

	bindings, err := r.listProjectIAM(ctx, config.Project, nameFilter)
	if err != nil {
		return nil, fmt.Errorf("verify project IAM: %w", err)
	}
	for _, binding := range bindings {
		result = append(result, residual{Kind: "project-iam", Role: binding.Role, Member: binding.Member})
	}

	return result, nil
}

func (r Runner) listCloudRun(ctx context.Context, config Config, nameFilter string) ([]cloudRunService, error) {
	var services []cloudRunService
	err := r.runJSON(ctx, &services,
		"run", "services", "list",
		"--project", config.Project,
		"--region", config.Region,
		"--filter", "metadata.name~'"+nameFilter+"'",
		"--format=json",
	)
	return services, err
}

func (r Runner) cloudRunPolicy(ctx context.Context, config Config, name string) ([]iamBinding, error) {
	output, err := r.query(ctx, "inspect Cloud Run IAM policy",
		"run", "services", "get-iam-policy", name,
		"--project", config.Project,
		"--region", config.Region,
		"--format=json",
	)
	if err != nil {
		return nil, err
	}
	return parseIAMPolicy(output)
}

func (r Runner) listZonal(ctx context.Context, group, resource, project, nameFilter string) ([]zonalResource, error) {
	var resources []zonalResource
	err := r.runJSON(ctx, &resources,
		group, resource, "list",
		"--project", project,
		"--filter", "name~'"+nameFilter+"'",
		"--format=json",
	)
	return resources, err
}

func (r Runner) listFirewalls(ctx context.Context, config Config, nameFilter string) ([]namedResource, error) {
	filter := "^(allow-ssh-ipv4-|allow-ssh-ipv6-|allow-rollout-ipv4-|allow-cloud-run-)" + strings.TrimPrefix(nameFilter, "^")
	return r.listNamed(ctx, []string{"compute", "firewall-rules", "list"}, config.Project, "name", filter)
}

func (r Runner) listServiceAccounts(ctx context.Context, config Config, nameFilter string) ([]serviceAccount, error) {
	filter := "^(vm-|internal-|ppb-)?" + strings.TrimPrefix(nameFilter, "^") + ".*@" + regexp.QuoteMeta(config.Project) + `\.iam\.gserviceaccount\.com$`
	var accounts []serviceAccount
	err := r.runJSON(ctx, &accounts,
		"iam", "service-accounts", "list",
		"--project", config.Project,
		"--filter", "email~'"+filter+"'",
		"--format=json",
	)
	return accounts, err
}

func (r Runner) listSubnetworks(ctx context.Context, project, nameFilter string) ([]regionalResource, error) {
	var resources []regionalResource
	err := r.runJSON(ctx, &resources,
		"compute", "networks", "subnets", "list",
		"--project", project,
		"--filter", "name~'"+nameFilter+"'",
		"--format=json",
	)
	return resources, err
}

func (r Runner) listNamed(ctx context.Context, prefix []string, project, field, filter string) ([]namedResource, error) {
	args := append([]string{}, prefix...)
	args = append(args, "--project", project, "--filter", field+"~'"+filter+"'", "--format=json")
	var resources []namedResource
	err := r.runJSON(ctx, &resources, args...)
	return resources, err
}

func (r Runner) listProjectIAM(ctx context.Context, project, nameFilter string) ([]projectIAMBinding, error) {
	output, err := r.query(ctx, "list project IAM bindings", "projects", "get-iam-policy", project, "--format=json")
	if err != nil {
		return nil, err
	}
	bindings, err := parseIAMPolicy(output)
	if err != nil {
		return nil, err
	}

	managedRoles := map[string]bool{
		"projects/" + project + "/roles/startVM":   true,
		"projects/" + project + "/roles/suspendVM": true,
		"roles/logging.logWriter":                  true,
		"roles/monitoring.metricWriter":            true,
	}
	ownedAccount := serviceAccountPattern(project, nameFilter)
	result := make([]projectIAMBinding, 0)
	for _, binding := range bindings {
		if !managedRoles[binding.Role] || !unconditional(binding.Condition) {
			continue
		}
		for _, member := range binding.Members {
			if ownedAccount.MatchString(member) {
				result = append(result, projectIAMBinding{Role: binding.Role, Member: member})
			}
		}
	}
	return result, nil
}

func (r Runner) runJSON(ctx context.Context, destination any, args ...string) error {
	description := strings.Join(args[:min(3, len(args))], " ")
	output, err := r.query(ctx, description, args...)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(output, destination); err != nil {
		return fmt.Errorf("decode gcloud JSON: %w", err)
	}
	return nil
}

func (r Runner) query(ctx context.Context, description string, args ...string) ([]byte, error) {
	var lastError error
	for attempt := 1; attempt <= r.queryAttempts; attempt++ {
		output, err := r.Command.Run(ctx, args...)
		if err == nil {
			return output, nil
		}
		lastError = err
		r.Logger.Warn("GCP cleanup query failed", "operation", description, "attempt", attempt, "error", r.Redactor.String(err.Error()))
		if attempt < r.queryAttempts {
			if err := r.Sleep(ctx, r.queryRetryDelay); err != nil {
				return nil, fmt.Errorf("wait before query retry: %w", err)
			}
		}
	}
	return nil, fmt.Errorf("exhausted %d query attempts: %w", r.queryAttempts, lastError)
}

func (r Runner) retry(ctx context.Context, config Config, description string, args []string) error {
	var lastError error
	for attempt := 1; attempt <= config.Attempts; attempt++ {
		r.Logger.Info("Running GCP cleanup mutation", "operation", description, "attempt", attempt)
		if _, err := r.Command.Run(ctx, args...); err == nil {
			return nil
		} else {
			lastError = err
			r.Logger.Warn("GCP cleanup mutation failed", "operation", description, "attempt", attempt, "error", r.Redactor.String(err.Error()))
		}
		if attempt < config.Attempts {
			if err := r.Sleep(ctx, config.RetryDelay); err != nil {
				return fmt.Errorf("wait before retry: %w", err)
			}
		}
	}
	return fmt.Errorf("exhausted %d attempts: %w", config.Attempts, lastError)
}

func (r Runner) retryNetwork(ctx context.Context, config Config, description string, args []string) error {
	var lastError error
	delay := config.RetryDelay
	attempt := 0
	for {
		attempt++
		r.Logger.Info("Running GCP network cleanup mutation", "operation", description, "attempt", attempt)
		if _, err := r.Command.Run(ctx, args...); err == nil {
			return nil
		} else {
			lastError = err
			r.Logger.Warn("GCP network cleanup mutation failed", "operation", description, "attempt", attempt, "error", r.Redactor.String(err.Error()))
		}

		if r.networkRetryBudget == nil || *r.networkRetryBudget <= 0 {
			break
		}
		wait := min(delay, *r.networkRetryBudget)
		if err := r.Sleep(ctx, wait); err != nil {
			return fmt.Errorf("wait before network cleanup retry: %w", err)
		}
		*r.networkRetryBudget -= wait
		if delay < time.Minute {
			delay = min(delay*2, time.Minute)
		}
	}
	return fmt.Errorf("exhausted shared network retry window after %d attempts: %w", attempt, lastError)
}

func normalizeConfig(config Config) (Config, error) {
	config.Project = strings.TrimSpace(config.Project)
	config.Region = strings.TrimSpace(config.Region)
	if config.Project == "" {
		return Config{}, errors.New("GCP project is required")
	}
	if config.Region == "" {
		return Config{}, errors.New("GCP region is required")
	}
	if _, err := targetNamePrefix(config.Target); err != nil {
		return Config{}, err
	}
	if config.Attempts <= 0 {
		config.Attempts = defaultAttempts
	}
	if config.RetryDelay < 0 {
		return Config{}, errors.New("retry delay cannot be negative")
	}
	if config.RetryDelay == 0 {
		config.RetryDelay = defaultDelay
	}
	if config.QueryAttempts <= 0 {
		config.QueryAttempts = defaultQueryAttempts
	}
	if config.QueryRetryDelay < 0 {
		return Config{}, errors.New("query retry delay cannot be negative")
	}
	if config.QueryRetryDelay == 0 {
		config.QueryRetryDelay = defaultQueryDelay
	}
	if config.NetworkRetryWindow < 0 {
		return Config{}, errors.New("network retry window cannot be negative")
	}
	if config.NetworkRetryWindow == 0 {
		config.NetworkRetryWindow = defaultNetworkRetryWindow
	}
	return config, nil
}

func targetNamePrefix(target string) (string, error) {
	provider, template, found := strings.Cut(target, "-")
	if !found || provider != "gcp" {
		return "", fmt.Errorf("unsupported GCP smoke target %q", target)
	}
	slug, ok := templateSlugs[template]
	if !ok {
		return "", fmt.Errorf("unsupported GCP smoke template %q", template)
	}
	return "cc-g-" + slug, nil
}

func normalizeRunID(runID string, limit int) string {
	var normalized strings.Builder
	for _, character := range strings.ToLower(runID) {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' {
			normalized.WriteRune(character)
		} else {
			normalized.WriteByte('-')
		}
		if normalized.Len() >= limit {
			break
		}
	}
	return normalized.String()
}

func parseIAMPolicy(output []byte) ([]iamBinding, error) {
	trimmed := bytes.TrimSpace(output)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, errors.New("IAM policy was not a JSON object")
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &envelope); err != nil {
		return nil, fmt.Errorf("decode IAM policy: %w", err)
	}
	rawBindings, found := envelope["bindings"]
	if !found {
		return nil, nil
	}
	rawBindings = bytes.TrimSpace(rawBindings)
	if len(rawBindings) == 0 || rawBindings[0] != '[' {
		return nil, errors.New("IAM policy bindings were not an array")
	}
	var bindings []iamBinding
	if err := json.Unmarshal(rawBindings, &bindings); err != nil {
		return nil, fmt.Errorf("decode IAM policy bindings: %w", err)
	}
	return bindings, nil
}

func hasUnconditionalMember(bindings []iamBinding, role, member string) bool {
	for _, binding := range bindings {
		if binding.Role != role || !unconditional(binding.Condition) {
			continue
		}
		for _, candidate := range binding.Members {
			if candidate == member {
				return true
			}
		}
	}
	return false
}

func unconditional(condition json.RawMessage) bool {
	condition = bytes.TrimSpace(condition)
	return len(condition) == 0 || bytes.Equal(condition, []byte("null"))
}

func firewallPattern(nameFilter string) *regexp.Regexp {
	return regexp.MustCompile("^(allow-ssh-ipv4-|allow-ssh-ipv6-|allow-rollout-ipv4-|allow-cloud-run-)" + strings.TrimPrefix(nameFilter, "^"))
}

func serviceAccountPattern(project, nameFilter string) *regexp.Regexp {
	return regexp.MustCompile(`^(deleted:)?serviceAccount:(vm-|internal-|ppb-)?` + strings.TrimPrefix(nameFilter, "^") + `.*@` + regexp.QuoteMeta(project) + `\.iam\.gserviceaccount\.com(\?uid=[^\s]+)?$`)
}

func resourceLocation(value string) (string, error) {
	value = strings.TrimSuffix(strings.TrimSpace(value), "/")
	if value == "" {
		return "", errors.New("resource location is empty")
	}
	if index := strings.LastIndexByte(value, '/'); index >= 0 {
		value = value[index+1:]
	}
	if value == "" {
		return "", errors.New("resource location is empty")
	}
	return value, nil
}

func sleepContext(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (f *failureList) add(operation string, err error, redactor *Redactor) {
	if err == nil {
		return
	}
	f.errors = append(f.errors, fmt.Errorf("%s: %s", operation, redactor.String(err.Error())))
}

func (f *failureList) addMessage(message string) {
	f.errors = append(f.errors, errors.New(message))
}

func (f *failureList) empty() bool {
	return len(f.errors) == 0
}

func (f *failureList) Error() string {
	messages := make([]string, 0, len(f.errors))
	for _, err := range f.errors {
		messages = append(messages, err.Error())
	}
	return "GCP smoke cleanup failed: " + strings.Join(messages, "; ")
}

func (f *failureList) Unwrap() []error {
	return f.errors
}
