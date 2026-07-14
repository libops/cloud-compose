package contracttest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func repositoryRoot(t testing.TB) string {
	t.Helper()

	directory, err := os.Getwd()
	if err != nil {
		t.Fatalf("resolve repository root: get working directory: %v", err)
	}

	for {
		if _, err := os.Stat(filepath.Join(directory, "go.mod")); err == nil {
			return directory
		} else if !os.IsNotExist(err) {
			t.Fatalf("resolve repository root: inspect %s: %v", directory, err)
		}

		parent := filepath.Dir(directory)
		if parent == directory {
			t.Fatal("resolve repository root: go.mod not found")
		}
		directory = parent
	}
}

func readRepositoryFile(t testing.TB, root, relativePath string) string {
	t.Helper()

	content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(relativePath)))
	if err != nil {
		t.Fatalf("read %s: %v", relativePath, err)
	}

	return string(content)
}

func requireContains(t testing.TB, text, expected, label string) {
	t.Helper()

	if !strings.Contains(text, expected) {
		t.Fatalf("could not find %s", label)
	}
}

func requireFirstSubmatch(t testing.TB, expression, text, label string) string {
	t.Helper()

	pattern, err := regexp.Compile(expression)
	if err != nil {
		t.Fatalf("compile pattern for %s: %v", label, err)
	}

	match := pattern.FindStringSubmatch(text)
	if len(match) < 2 {
		t.Fatalf("could not find %s", label)
	}

	return match[1]
}

func prettyJSON(t testing.TB, value any) string {
	t.Helper()

	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatalf("format contract value: %v", err)
	}

	return string(encoded)
}
