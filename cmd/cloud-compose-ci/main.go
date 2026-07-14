// Command cloud-compose-ci runs compiled cloud-compose CI lifecycle operations.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/libops/cloud-compose/internal/gcpcleanup"
	"github.com/libops/cloud-compose/internal/runnamespace"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	redactor := gcpcleanup.NewEnvironmentRedactor(os.Environ())
	commander := gcpcleanup.ExecCommander{Stderr: os.Stderr, Redactor: redactor}
	os.Exit(run(ctx, os.Args[1:], os.Getenv, os.Stdout, os.Stderr, commander, redactor))
}

func run(
	ctx context.Context,
	args []string,
	getenv func(string) string,
	stdout io.Writer,
	stderr io.Writer,
	commander gcpcleanup.Commander,
	redactor *gcpcleanup.Redactor,
) int {
	if len(args) < 2 || args[0] != "gcp" {
		printUsage(stderr)
		return 2
	}

	switch args[1] {
	case "namespace":
		return runGCPNamespace(args[2:], stdout, stderr)
	case "sweep":
		return runGCPSweep(ctx, args[2:], getenv, stderr, commander, redactor)
	default:
		printUsage(stderr)
		return 2
	}
}

func runGCPNamespace(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("cloud-compose-ci gcp namespace", flag.ContinueOnError)
	flags.SetOutput(stderr)
	runID := flags.String("run-id", "", "canonical decimal GitHub Actions run ID")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "cloud-compose-ci gcp namespace does not accept positional arguments")
		return 2
	}

	namespace, err := runnamespace.Encode(*runID)
	if err != nil {
		fmt.Fprintf(stderr, "invalid --run-id: %s\n", err)
		return 2
	}
	if _, err := fmt.Fprintln(stdout, namespace); err != nil {
		fmt.Fprintf(stderr, "write namespace: %s\n", err)
		return 1
	}
	return 0
}

func runGCPSweep(
	ctx context.Context,
	args []string,
	getenv func(string) string,
	stderr io.Writer,
	commander gcpcleanup.Commander,
	redactor *gcpcleanup.Redactor,
) int {
	flags := flag.NewFlagSet("cloud-compose-ci gcp sweep", flag.ContinueOnError)
	flags.SetOutput(stderr)
	project := flags.String("project", getenv("GCLOUD_PROJECT"), "GCP project containing smoke resources")
	region := flags.String("region", environmentDefault(getenv, "GCLOUD_REGION", "us-east5"), "GCP region containing Cloud Run resources")
	target := flags.String("target", "gcp-wp", "cloud-compose smoke target")
	runID := flags.String("run-id", getenv("CLOUD_COMPOSE_SMOKE_RUN_ID"), "originating workflow run ID")
	allRuns := flags.Bool("all-runs", false, "sweep every run for the target; intended only for explicit orphan cleanup")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "cloud-compose-ci gcp sweep does not accept positional arguments")
		return 2
	}
	if strings.TrimSpace(*project) == "" {
		fmt.Fprintln(stderr, "--project or GCLOUD_PROJECT is required")
		return 2
	}
	runIDExplicit := false
	flags.Visit(func(parsed *flag.Flag) {
		if parsed.Name == "run-id" {
			runIDExplicit = true
		}
	})
	if *allRuns && runIDExplicit {
		fmt.Fprintln(stderr, "--run-id and --all-runs are mutually exclusive")
		return 2
	}
	effectiveRunID := *runID
	if *allRuns {
		// An explicit broad sweep overrides a run ID inherited from the
		// environment. Only an explicitly supplied --run-id is a conflict.
		effectiveRunID = ""
	}
	if effectiveRunID == "" && !*allRuns {
		fmt.Fprintln(stderr, "--run-id or CLOUD_COMPOSE_SMOKE_RUN_ID is required unless --all-runs is set")
		return 2
	}

	logger := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	runner := gcpcleanup.Runner{
		Command:  commander,
		Logger:   logger,
		Redactor: redactor,
	}
	err := runner.Sweep(ctx, gcpcleanup.Config{
		Project:      *project,
		Region:       *region,
		Target:       *target,
		RunID:        effectiveRunID,
		AllowAllRuns: *allRuns,
	})
	if err != nil {
		fmt.Fprintf(stderr, "GCP cleanup failed: %s\n", redactor.String(err.Error()))
		return 1
	}
	return 0
}

func environmentDefault(getenv func(string) string, name, fallback string) string {
	if value := getenv(name); value != "" {
		return value
	}
	return fallback
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "Usage:")
	fmt.Fprintln(writer, "  cloud-compose-ci gcp namespace --run-id RUN_ID")
	fmt.Fprintln(writer, "  cloud-compose-ci gcp sweep [--project PROJECT] [--region REGION] [--target gcp-wp] (--run-id RUN_ID | --all-runs)")
}
