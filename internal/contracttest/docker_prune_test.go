package contracttest

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestDockerPrunePreservesNamedRollbackImages(t *testing.T) {
	root := repositoryRoot(t)
	script := filepath.Join(root, "rootfs", "home", "cloud-compose", "docker-prune.sh")
	temporary := t.TempDir()
	profile := filepath.Join(temporary, "profile.sh")
	lock := filepath.Join(temporary, "docker-prune.lock")
	logPath := filepath.Join(temporary, "docker.log")
	binDirectory := filepath.Join(temporary, "bin")

	if err := os.Mkdir(binDirectory, 0o755); err != nil {
		t.Fatalf("create mock binary directory: %v", err)
	}
	if err := os.WriteFile(profile, []byte("# test profile\n"), 0o600); err != nil {
		t.Fatalf("write test profile: %v", err)
	}
	mockDocker := []byte("#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$*\" >> \"${DOCKER_PRUNE_TEST_LOG:?}\"\n")
	if err := os.WriteFile(filepath.Join(binDirectory, "docker"), mockDocker, 0o755); err != nil {
		t.Fatalf("write mock Docker binary: %v", err)
	}

	command := exec.Command("bash", script)
	command.Env = append(os.Environ(),
		"CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED=true",
		"CLOUD_COMPOSE_DOCKER_PRUNE_LOCK_PATH="+lock,
		"CLOUD_COMPOSE_DOCKER_PRUNE_UNTIL=72h",
		"CLOUD_COMPOSE_PROFILE_PATH="+profile,
		"DOCKER_PRUNE_TEST_LOG="+logPath,
		"PATH="+binDirectory+":"+os.Getenv("PATH"),
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("run Docker prune policy: %v\n%s", err, output)
	}

	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read Docker invocation log: %v", err)
	}
	commands := strings.Split(strings.TrimSpace(string(logBytes)), "\n")
	want := []string{
		"container prune --force --filter until=72h",
		"network prune --force --filter until=72h",
		"image prune --force --filter until=72h",
		"builder prune --force --filter until=72h",
	}
	if !slices.Equal(commands, want) {
		t.Fatalf("Docker prune commands = %#v, want %#v", commands, want)
	}
	for _, invocation := range commands {
		if strings.Contains(invocation, "system prune") || strings.Contains(invocation, "image prune --all") {
			t.Fatalf("destructive Docker prune invocation remains: %s", invocation)
		}
	}
}

func TestDockerPruneIsDisabledByDefault(t *testing.T) {
	root := repositoryRoot(t)
	script := filepath.Join(root, "rootfs", "home", "cloud-compose", "docker-prune.sh")
	temporary := t.TempDir()
	profile := filepath.Join(temporary, "profile.sh")
	if err := os.WriteFile(profile, []byte("# test profile\n"), 0o600); err != nil {
		t.Fatalf("write test profile: %v", err)
	}

	command := exec.Command("bash", script)
	command.Env = append(os.Environ(),
		"CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED=",
		"CLOUD_COMPOSE_PROFILE_PATH="+profile,
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("run disabled Docker prune policy: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "Docker pruning is disabled") {
		t.Fatalf("disabled Docker prune output = %q", output)
	}
}
