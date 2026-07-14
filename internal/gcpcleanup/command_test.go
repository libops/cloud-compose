package gcpcleanup

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestExecCommanderRedactsStderr(t *testing.T) {
	if os.Getenv("GO_WANT_GCLOUD_HELPER") == "1" {
		fmt.Fprintln(os.Stderr, "provider rejected top-secret-token")
		os.Exit(1)
	}
	t.Setenv("GO_WANT_GCLOUD_HELPER", "1")

	var stderr bytes.Buffer
	commander := ExecCommander{
		Path:     os.Args[0],
		Stderr:   &stderr,
		Redactor: NewRedactor("top-secret-token"),
	}
	_, err := commander.Run(context.Background(), "-test.run=TestExecCommanderRedactsStderr")
	if err == nil {
		t.Fatal("Run() unexpectedly succeeded")
	}
	if strings.Contains(stderr.String(), "top-secret-token") {
		t.Fatalf("stderr leaked secret: %s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "[REDACTED]") {
		t.Fatalf("stderr did not contain redaction marker: %s", stderr.String())
	}
}

func TestNewEnvironmentRedactor(t *testing.T) {
	t.Parallel()
	redactor := NewEnvironmentRedactor([]string{
		"PATH=/usr/bin",
		"CLOUDSDK_AUTH_ACCESS_TOKEN=access-value",
		"GOOGLE_APPLICATION_CREDENTIALS=/private/credential.json",
	})
	got := redactor.String("access-value /private/credential.json /usr/bin")
	want := "[REDACTED] [REDACTED] /usr/bin"
	if got != want {
		t.Errorf("String() = %q; want %q", got, want)
	}
}
