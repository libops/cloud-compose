package contracttest

import (
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

var expectedRollout = []string{
	`sitectl:default rollout`,
}

type rolloutSource struct {
	label        string
	relativePath string
	commands     []string
}

func TestRolloutParityContract(t *testing.T) {
	root := repositoryRoot(t)
	sources := []rolloutSource{
		{
			label:        "GCP Terraform",
			relativePath: "modules/gcp/variables.tf",
			commands: parseHCLRollout(
				t,
				root,
				"modules/gcp/variables.tf",
				`(?ms)^variable "docker_compose_rollout" \{.*?^  default = \[\n(.*?)^  \]\n`,
				"GCP Terraform default rollout list",
			),
		},
		{
			label:        "Linux VM Terraform",
			relativePath: "modules/linux-vm-runtime/variables.tf",
			commands: parseHCLRollout(
				t,
				root,
				"modules/linux-vm-runtime/variables.tf",
				`(?ms)^variable "docker_compose_rollout" \{.*?^  default = \[\n(.*?)^  \]\n`,
				"Linux VM Terraform default rollout list",
			),
		},
		{
			label:        "Ansible",
			relativePath: "ansible/roles/cloud_compose/defaults/main.yml",
			commands:     parseAnsibleRollout(t, root),
		},
		{
			label:        "Salt",
			relativePath: "salt/cloud-compose/init.sls",
			commands:     parseSaltRollout(t, root),
		},
		{
			label:        "rollout documentation",
			relativePath: "docs/rollout.md",
			commands: parseHCLRollout(
				t,
				root,
				"docs/rollout.md",
				`(?ms)^      rollout = \[\n(.*?)^      \]\n`,
				"documented rollout list",
			),
		},
	}

	for _, source := range sources {
		if !slices.Equal(source.commands, expectedRollout) {
			t.Errorf("%s rollout list in %s diverged:\nexpected %s\nactual   %s", source.label, source.relativePath, prettyJSON(t, expectedRollout), prettyJSON(t, source.commands))
		}

		content := readRepositoryFile(t, root, source.relativePath)
		if strings.Contains(content, "scripts/rollout.sh") {
			t.Errorf("%s still delegates lifecycle ownership to scripts/rollout.sh", source.label)
		}
	}

	composeVersions := checkComposeVersions(t, root)
	var expectedVersion string
	for _, source := range composeVersions {
		if expectedVersion == "" {
			expectedVersion = source.version
			continue
		}
		if source.version != expectedVersion {
			t.Errorf("Docker Compose defaults diverged: %s is %s; expected %s", source.label, source.version, expectedVersion)
		}
	}

	renovate := readRepositoryFile(t, root, "renovate.json5")
	for _, marker := range []string{
		"Update Docker Compose configuration-management defaults",
		"ansible/roles/cloud_compose/defaults/main",
		"salt/cloud-compose/init",
	} {
		requireContains(t, renovate, marker, fmt.Sprintf("Renovate configuration-management marker %q", marker))
	}
}

func parseHCLRollout(t testing.TB, root, relativePath, expression, label string) []string {
	t.Helper()

	content := readRepositoryFile(t, root, relativePath)
	block := requireFirstSubmatch(t, expression, content, label)
	commands := make([]string, 0, len(expectedRollout))
	for _, rawLine := range strings.Split(block, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}
		line = strings.TrimSuffix(line, ",")

		var command string
		if err := json.Unmarshal([]byte(line), &command); err != nil {
			t.Fatalf("could not parse %s command %q: %v", label, line, err)
		}
		commands = append(commands, strings.ReplaceAll(command, "$${", "${"))
	}

	return commands
}

func parseAnsibleRollout(t testing.TB, root string) []string {
	t.Helper()

	const relativePath = "ansible/roles/cloud_compose/defaults/main.yml"
	content := readRepositoryFile(t, root, relativePath)
	block := requireFirstSubmatch(t, `(?m)^cloud_compose_default_rollout:\n((^  - .*\n)+)`, content, "Ansible default rollout list")
	linePattern := regexp.MustCompile(`^  - '(.*)'$`)
	commands := make([]string, 0, len(expectedRollout))
	for _, rawLine := range strings.Split(strings.TrimSuffix(block, "\n"), "\n") {
		match := linePattern.FindStringSubmatch(rawLine)
		if len(match) != 2 {
			t.Fatalf("could not parse Ansible rollout command %q", rawLine)
		}
		commands = append(commands, match[1])
	}

	return commands
}

func parseSaltRollout(t testing.TB, root string) []string {
	t.Helper()

	const relativePath = "salt/cloud-compose/init.sls"
	content := readRepositoryFile(t, root, relativePath)
	block := requireFirstSubmatch(t, `(?ms)^\{% set default_rollout = \[\n(.*?)^\] %\}`, content, "Salt default rollout list")
	commands := make([]string, 0, len(expectedRollout))
	for _, rawLine := range strings.Split(block, "\n") {
		line := strings.TrimSuffix(strings.TrimSpace(rawLine), ",")
		if line == "" {
			continue
		}

		command, err := unquoteSaltString(line)
		if err != nil {
			t.Fatalf("could not parse Salt rollout command %q: %v", line, err)
		}
		commands = append(commands, command)
	}

	return commands
}

func unquoteSaltString(literal string) (string, error) {
	if len(literal) < 2 || literal[0] != literal[len(literal)-1] {
		return "", fmt.Errorf("not a quoted string")
	}
	if literal[0] == '"' {
		return strconv.Unquote(literal)
	}
	if literal[0] != '\'' {
		return "", fmt.Errorf("unsupported string delimiter %q", literal[0])
	}

	inner := literal[1 : len(literal)-1]
	var converted strings.Builder
	converted.Grow(len(literal) + 2)
	converted.WriteByte('"')
	for index := 0; index < len(inner); index++ {
		character := inner[index]
		if character == '\\' && index+1 < len(inner) {
			next := inner[index+1]
			if next == '\'' {
				converted.WriteByte('\'')
				index++
				continue
			}
			converted.WriteByte(character)
			converted.WriteByte(next)
			index++
			continue
		}
		if character == '"' {
			converted.WriteByte('\\')
		}
		converted.WriteByte(character)
	}
	converted.WriteByte('"')

	return strconv.Unquote(converted.String())
}

func TestUnquoteSaltString(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		literal string
		want    string
		wantErr bool
	}{
		{name: "single quoted", literal: `'say "hello"'`, want: `say "hello"`},
		{name: "escaped single quote", literal: `'it\'s ready'`, want: `it's ready`},
		{name: "escaped backslash", literal: `'C:\\tmp'`, want: `C:\tmp`},
		{name: "double quoted", literal: `"line\nnext"`, want: "line\nnext"},
		{name: "unquoted", literal: "command", wantErr: true},
		{name: "mismatched delimiters", literal: `'command"`, wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			got, err := unquoteSaltString(test.literal)
			if test.wantErr {
				if err == nil {
					t.Fatalf("unquoteSaltString(%q) unexpectedly succeeded with %q", test.literal, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unquoteSaltString(%q): %v", test.literal, err)
			}
			if got != test.want {
				t.Errorf("unquoteSaltString(%q) = %q; want %q", test.literal, got, test.want)
			}
		})
	}
}

type composeVersionSource struct {
	label        string
	relativePath string
	expression   string
	version      string
}

func checkComposeVersions(t testing.TB, root string) []composeVersionSource {
	t.Helper()

	sources := []composeVersionSource{
		{label: "root Terraform", relativePath: "variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "GCP provider", relativePath: "providers/gcp/variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "DigitalOcean provider", relativePath: "providers/do/variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "Linode provider", relativePath: "providers/linode/variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "DigitalOcean module", relativePath: "modules/digitalocean/variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "Linode module", relativePath: "modules/linode/variables.tf", expression: `compose_version\s*=\s*optional\(string,\s*"([^"]+)"\)`},
		{label: "GCP module", relativePath: "modules/gcp/variables.tf", expression: `(?ms)variable "docker_compose_version" \{.*?default\s*=\s*"([^"]+)"`},
		{label: "Linux VM module", relativePath: "modules/linux-vm-runtime/variables.tf", expression: `(?ms)variable "docker_compose_version" \{.*?default\s*=\s*"([^"]+)"`},
		{label: "Ansible", relativePath: "ansible/roles/cloud_compose/defaults/main.yml", expression: `(?m)^cloud_compose_docker_compose_version:\s*(\S+)\s*$`},
		{label: "Salt", relativePath: "salt/cloud-compose/init.sls", expression: `docker\.get\('compose_version',\s*cc\.get\('docker_compose_version',\s*'([^']+)'\)\)`},
	}

	releaseTag := regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	for index := range sources {
		source := &sources[index]
		content := readRepositoryFile(t, root, source.relativePath)
		source.version = requireFirstSubmatch(t, source.expression, content, source.label+" Docker Compose default")
		if !releaseTag.MatchString(source.version) {
			t.Errorf("%s has an invalid Docker Compose release tag: %q", source.label, source.version)
		}
	}

	return sources
}
