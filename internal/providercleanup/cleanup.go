package providercleanup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/libops/cloud-compose/internal/runnamespace"
)

const (
	defaultDeleteAttempts     = 12
	defaultDeleteRetryDelay   = 10 * time.Second
	defaultListAttempts       = 6
	defaultListRetryDelay     = 2 * time.Second
	defaultVerifyAttempts     = 6
	defaultVerifyRetryDelay   = 10 * time.Second
	defaultComputeSettleDelay = 10 * time.Second
	maximumListRetryDelay     = 30 * time.Second
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

// Scope identifies the smoke-test family whose resources are being removed.
type Scope string

const (
	// ApplicationScope selects the provider-neutral app smoke fixtures.
	ApplicationScope Scope = "application"
	// ConfigManagementScope selects the raw-host Ansible or Salt smoke fixture.
	ConfigManagementScope Scope = "config-management"
)

// ParseScope validates a cleanup scope.
func ParseScope(value string) (Scope, error) {
	scope := Scope(strings.ToLower(strings.TrimSpace(value)))
	switch scope {
	case ApplicationScope, ConfigManagementScope:
		return scope, nil
	default:
		return "", fmt.Errorf("unsupported cleanup scope %q", value)
	}
}

// Config identifies one exact smoke-run resource set, or an explicitly
// authorized target-wide orphan sweep.
type Config struct {
	Provider           Provider
	Scope              Scope
	Target             string
	RunID              string
	AllowAllRuns       bool
	DeleteAttempts     int
	DeleteRetryDelay   time.Duration
	ListAttempts       int
	ListRetryDelay     time.Duration
	VerifyAttempts     int
	VerifyRetryDelay   time.Duration
	ComputeSettleDelay time.Duration
}

// Runner performs ordered and idempotent provider resource cleanup.
type Runner struct {
	Client *Client
	Logger *slog.Logger
	Sleep  func(context.Context, time.Duration) error
}

// Sweep removes only resources whose provider metadata matches the requested
// target and run ownership.
func (r Runner) Sweep(ctx context.Context, config Config) error {
	config, ownership, err := normalizeConfig(config)
	if err != nil {
		return err
	}
	if r.Client == nil {
		return errors.New("provider cleanup client is required")
	}
	if r.Client.provider != config.Provider {
		return errors.New("provider cleanup client does not match the requested provider")
	}
	logger := r.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	sleep := r.Sleep
	if sleep == nil {
		sleep = sleepContext
	}
	r.Logger = logger
	r.Sleep = sleep

	failures := &failureList{}
	for _, kind := range resourceKinds(config.Provider) {
		resources, listErr := r.listWithRetry(ctx, config, kind)
		if listErr != nil {
			failures.add(fmt.Sprintf("list %s %s", config.Provider, kind), listErr)
			continue
		}

		deleted := 0
		for _, candidate := range resources {
			if !ownership.owns(kind, candidate) {
				continue
			}
			if deleteErr := r.deleteWithRetry(ctx, config, kind, candidate.ID); deleteErr != nil {
				failures.add(fmt.Sprintf("delete %s %s %s", config.Provider, kind, candidate.ID), deleteErr)
				continue
			}
			deleted++
		}

		if deleted > 0 && isComputeKind(kind) && config.ComputeSettleDelay > 0 {
			if sleepErr := r.Sleep(ctx, config.ComputeSettleDelay); sleepErr != nil {
				failures.add("wait for compute deletion to settle", sleepErr)
				break
			}
		}
	}

	if verifyErr := r.verify(ctx, config, ownership); verifyErr != nil {
		failures.add("verify provider cleanup", verifyErr)
	}
	if failures.empty() {
		logger.Info("provider smoke cleanup completed",
			"provider", config.Provider,
			"scope", config.Scope,
			"target", config.Target,
			"run_id", config.RunID,
		)
		return nil
	}
	return failures
}

func (r Runner) listWithRetry(ctx context.Context, config Config, kind resourceKind) ([]resource, error) {
	delay := config.ListRetryDelay
	var err error
	for attempt := 1; attempt <= config.ListAttempts; attempt++ {
		var resources []resource
		resources, err = r.Client.list(ctx, kind)
		if err == nil {
			return resources, nil
		}
		if !retryable(err) || attempt == config.ListAttempts {
			break
		}
		r.Logger.Warn("retrying provider resource list",
			"provider", config.Provider,
			"kind", kind,
			"attempt", attempt+1,
			"attempts", config.ListAttempts,
		)
		if sleepErr := r.Sleep(ctx, delay); sleepErr != nil {
			return nil, sleepErr
		}
		delay *= 2
		if delay > maximumListRetryDelay {
			delay = maximumListRetryDelay
		}
	}
	return nil, err
}

func (r Runner) deleteWithRetry(ctx context.Context, config Config, kind resourceKind, id string) error {
	var err error
	for attempt := 1; attempt <= config.DeleteAttempts; attempt++ {
		r.Logger.Info("deleting provider smoke resource",
			"provider", config.Provider,
			"kind", kind,
			"id", id,
			"attempt", attempt,
		)
		err = r.Client.delete(ctx, kind, id)
		if err == nil {
			return nil
		}
		if !retryable(err) || attempt == config.DeleteAttempts {
			break
		}
		if sleepErr := r.Sleep(ctx, config.DeleteRetryDelay); sleepErr != nil {
			return sleepErr
		}
	}
	return err
}

func (r Runner) verify(ctx context.Context, config Config, ownership ownership) error {
	var residuals []string
	var err error
	for attempt := 1; attempt <= config.VerifyAttempts; attempt++ {
		residuals, err = r.residuals(ctx, config, ownership)
		if err == nil && len(residuals) == 0 {
			return nil
		}
		if attempt == config.VerifyAttempts {
			break
		}
		r.Logger.Warn("provider cleanup verification found residual resources",
			"provider", config.Provider,
			"target", config.Target,
			"count", len(residuals),
			"attempt", attempt,
		)
		if sleepErr := r.Sleep(ctx, config.VerifyRetryDelay); sleepErr != nil {
			return sleepErr
		}
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("provider cleanup left matching resources: %s", strings.Join(residuals, ", "))
}

func (r Runner) residuals(ctx context.Context, config Config, ownership ownership) ([]string, error) {
	var residuals []string
	for _, kind := range resourceKinds(config.Provider) {
		resources, err := r.listWithRetry(ctx, config, kind)
		if err != nil {
			return nil, err
		}
		for _, candidate := range resources {
			if ownership.owns(kind, candidate) {
				residuals = append(residuals, fmt.Sprintf("%s/%s", kind, candidate.ID))
			}
		}
	}
	slices.Sort(residuals)
	return residuals, nil
}

type ownership struct {
	provider        Provider
	requiredTags    []string
	firewallPattern *regexp.Regexp
}

func (o ownership) owns(kind resourceKind, candidate resource) bool {
	if o.provider == DigitalOcean && kind == kindFirewalls {
		return o.firewallPattern != nil && o.firewallPattern.MatchString(candidate.Name)
	}
	for _, required := range o.requiredTags {
		if !slices.Contains(candidate.Tags, required) {
			return false
		}
	}
	return true
}

func normalizeConfig(config Config) (Config, ownership, error) {
	provider, err := ParseProvider(string(config.Provider))
	if err != nil {
		return Config{}, ownership{}, err
	}
	config.Provider = provider
	if config.Scope == "" {
		config.Scope = ApplicationScope
	}
	scope, err := ParseScope(string(config.Scope))
	if err != nil {
		return Config{}, ownership{}, err
	}
	config.Scope = scope
	config.Target = strings.ToLower(strings.TrimSpace(config.Target))
	config.RunID = strings.TrimSpace(config.RunID)
	if config.RunID != "" && config.AllowAllRuns {
		return Config{}, ownership{}, errors.New("run ID and all-run cleanup are mutually exclusive")
	}
	if config.RunID == "" && !config.AllowAllRuns {
		return Config{}, ownership{}, errors.New("run ID is required unless all-run cleanup is explicitly enabled")
	}
	if config.RunID != "" {
		if _, err := runnamespace.Encode(config.RunID); err != nil {
			return Config{}, ownership{}, fmt.Errorf("invalid run ID: %w", err)
		}
	}

	resourceOwnership, err := buildOwnership(config)
	if err != nil {
		return Config{}, ownership{}, err
	}
	applyDefaults(&config)
	if err := validateRetryConfig(config); err != nil {
		return Config{}, ownership{}, err
	}
	return config, resourceOwnership, nil
}

func buildOwnership(config Config) (ownership, error) {
	requiredTags := []string{"cloud-compose-smoke"}
	resourceOwnership := ownership{provider: config.Provider}
	switch config.Scope {
	case ApplicationScope:
		providerPrefix := string(config.Provider) + "-"
		if !strings.HasPrefix(config.Target, providerPrefix) {
			return ownership{}, fmt.Errorf("application target %q does not belong to provider %s", config.Target, config.Provider)
		}
		template := strings.TrimPrefix(config.Target, providerPrefix)
		templateSlug, found := templateSlugs[template]
		if !found {
			return ownership{}, fmt.Errorf("unsupported application smoke target %q", config.Target)
		}
		requiredTags = append(requiredTags, config.Target)
		if config.Provider == DigitalOcean {
			prefix := "cc-do-" + templateSlug + "-"
			var namePattern string
			if config.RunID != "" {
				namePattern = "^" + regexp.QuoteMeta(prefix+config.RunID) + `-[0-9a-f]{6}-cloud-compose$`
			} else {
				namePattern = "^" + regexp.QuoteMeta(prefix) + `(?:[a-z0-9-]+-)?[0-9a-f]{6}-cloud-compose$`
			}
			resourceOwnership.firewallPattern = regexp.MustCompile(namePattern)
		}
	case ConfigManagementScope:
		if config.Provider != Linode {
			return ownership{}, errors.New("config-management smoke cleanup is supported only on Linode")
		}
		if config.Target != "ansible-drupal" && config.Target != "salt-drupal" {
			return ownership{}, fmt.Errorf("unsupported config-management smoke target %q", config.Target)
		}
		requiredTags = append(requiredTags, "config-management-smoke", "config-management-"+config.Target)
	}
	if config.RunID != "" {
		requiredTags = append(requiredTags, "gha-run-"+config.RunID)
	}
	resourceOwnership.requiredTags = requiredTags
	return resourceOwnership, nil
}

func applyDefaults(config *Config) {
	if config.DeleteAttempts == 0 {
		config.DeleteAttempts = defaultDeleteAttempts
	}
	if config.DeleteRetryDelay == 0 {
		config.DeleteRetryDelay = defaultDeleteRetryDelay
	}
	if config.ListAttempts == 0 {
		config.ListAttempts = defaultListAttempts
	}
	if config.ListRetryDelay == 0 {
		config.ListRetryDelay = defaultListRetryDelay
	}
	if config.VerifyAttempts == 0 {
		config.VerifyAttempts = defaultVerifyAttempts
	}
	if config.VerifyRetryDelay == 0 {
		config.VerifyRetryDelay = defaultVerifyRetryDelay
	}
	if config.ComputeSettleDelay == 0 {
		config.ComputeSettleDelay = defaultComputeSettleDelay
	}
}

func validateRetryConfig(config Config) error {
	if config.DeleteAttempts < 1 || config.ListAttempts < 1 || config.VerifyAttempts < 1 {
		return errors.New("provider cleanup attempt counts must be positive")
	}
	if config.DeleteRetryDelay < 0 || config.ListRetryDelay < 0 || config.VerifyRetryDelay < 0 || config.ComputeSettleDelay < 0 {
		return errors.New("provider cleanup retry delays cannot be negative")
	}
	return nil
}

func resourceKinds(provider Provider) []resourceKind {
	if provider == DigitalOcean {
		return []resourceKind{kindFirewalls, kindDroplets, kindVolumes}
	}
	return []resourceKind{kindFirewalls, kindInstances, kindVolumes}
}

func isComputeKind(kind resourceKind) bool {
	return kind == kindDroplets || kind == kindInstances
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

type failureList struct {
	errors []error
}

func (f *failureList) add(operation string, err error) {
	if err != nil {
		f.errors = append(f.errors, fmt.Errorf("%s: %w", operation, err))
	}
}

func (f *failureList) empty() bool {
	return len(f.errors) == 0
}

func (f *failureList) Error() string {
	messages := make([]string, 0, len(f.errors))
	for _, err := range f.errors {
		messages = append(messages, err.Error())
	}
	return "provider smoke cleanup failed: " + strings.Join(messages, "; ")
}

func (f *failureList) Unwrap() []error {
	return f.errors
}
