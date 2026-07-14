// Package gcpcleanup removes GCP resources owned by a cloud-compose smoke run.
package gcpcleanup

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"slices"
	"strings"
)

// Commander executes one gcloud command and returns its standard output.
type Commander interface {
	Run(context.Context, ...string) ([]byte, error)
}

// ExecCommander invokes the installed gcloud CLI without a shell.
type ExecCommander struct {
	Path     string
	Stderr   io.Writer
	Redactor *Redactor
}

// Run executes gcloud with the supplied arguments.
func (c ExecCommander) Run(ctx context.Context, args ...string) ([]byte, error) {
	path := c.Path
	if path == "" {
		path = "gcloud"
	}
	redactor := c.Redactor
	if redactor == nil {
		redactor = NewRedactor()
	}

	// Arguments are passed directly to gcloud without a shell. Cleanup constructs
	// every command from validated target prefixes, provider-returned owned names,
	// and fixed flag names.
	command := exec.CommandContext(ctx, path, args...) // #nosec G204
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	err := command.Run()
	if stderr.Len() > 0 && c.Stderr != nil {
		message := strings.TrimSpace(redactor.String(stderr.String()))
		if message != "" {
			_, _ = fmt.Fprintln(c.Stderr, message)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("gcloud command failed: %w", err)
	}

	return stdout.Bytes(), nil
}

// Redactor replaces configured secret values before errors reach CI logs.
type Redactor struct {
	secrets []string
}

// NewRedactor constructs a redactor from non-empty secret values.
func NewRedactor(secrets ...string) *Redactor {
	filtered := make([]string, 0, len(secrets))
	for _, secret := range secrets {
		if secret != "" && !slices.Contains(filtered, secret) {
			filtered = append(filtered, secret)
		}
	}
	slices.SortFunc(filtered, func(left, right string) int {
		return len(right) - len(left)
	})
	return &Redactor{secrets: filtered}
}

// NewEnvironmentRedactor discovers sensitive values in an environment snapshot.
func NewEnvironmentRedactor(environment []string) *Redactor {
	secrets := make([]string, 0)
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if !found || value == "" || !sensitiveEnvironmentName(name) {
			continue
		}
		secrets = append(secrets, value)
	}
	return NewRedactor(secrets...)
}

// String returns text with all configured secret values replaced.
func (r *Redactor) String(value string) string {
	if r == nil {
		return value
	}
	for _, secret := range r.secrets {
		value = strings.ReplaceAll(value, secret, "[REDACTED]")
	}
	return value
}

func sensitiveEnvironmentName(name string) bool {
	name = strings.ToUpper(name)
	for _, marker := range []string{"TOKEN", "PASSWORD", "SECRET", "CREDENTIAL", "PRIVATE_KEY"} {
		if strings.Contains(name, marker) {
			return true
		}
	}
	return false
}
