package contracttest

import (
	"encoding/json"
	"maps"
	"slices"
	"testing"
)

type templateRegistry struct {
	Default   templateDefinition            `json:"default"`
	Templates map[string]templateDefinition `json:"templates"`
}

type templateDefinition struct {
	Branch          string            `json:"branch"`
	Packages        []string          `json:"packages"`
	PackageVersions map[string]string `json:"package_versions"`
}

func TestTemplateVersionContract(t *testing.T) {
	root := repositoryRoot(t)
	registryContent := readRepositoryFile(t, root, "templates/apps.json")

	var registry templateRegistry
	if err := json.Unmarshal([]byte(registryContent), &registry); err != nil {
		t.Fatalf("parse templates/apps.json: %v", err)
	}

	expectedVersions := map[string]map[string]string{
		"default": {
			"sitectl": "v1.0.0",
		},
		"archivesspace": {
			"sitectl":               "v1.0.0",
			"sitectl-archivesspace": "v1.0.0",
		},
		"drupal": {
			"sitectl":        "v1.0.0",
			"sitectl-drupal": "v1.0.0",
		},
		// ISLE remains on its last released pre-v1 compatibility set until
		// the outstanding ISLE components are ready for a coordinated v1.
		"isle": {
			"sitectl":        "v0.40.0",
			"sitectl-drupal": "v0.12.0",
			"sitectl-isle":   "v0.19.0",
		},
		"ojs": {
			"sitectl":     "v1.0.0",
			"sitectl-ojs": "v1.0.0",
		},
		"omeka-classic": {
			"sitectl":               "v1.0.0",
			"sitectl-omeka-classic": "v1.0.0",
		},
		"omeka-s": {
			"sitectl":         "v1.0.0",
			"sitectl-omeka-s": "v1.0.0",
		},
		"wp": {
			"sitectl":    "v1.0.0",
			"sitectl-wp": "v1.0.0",
		},
	}

	if !maps.Equal(registry.Default.PackageVersions, expectedVersions["default"]) {
		t.Errorf("template %q package versions diverged:\nexpected %s\nactual   %s", "default", prettyJSON(t, expectedVersions["default"]), prettyJSON(t, registry.Default.PackageVersions))
	}

	for _, name := range slices.Sorted(maps.Keys(expectedVersions)) {
		if name == "default" {
			continue
		}
		expected := expectedVersions[name]
		definition, ok := registry.Templates[name]
		if !ok {
			t.Errorf("template %q is missing", name)
			continue
		}
		if !maps.Equal(definition.PackageVersions, expected) {
			t.Errorf("template %q package versions diverged:\nexpected %s\nactual   %s", name, prettyJSON(t, expected), prettyJSON(t, definition.PackageVersions))
		}
		if definition.Branch != "v1.0.0" {
			t.Errorf("template %q branch = %q, want stable contract v1.0.0", name, definition.Branch)
		}
	}

	checkPackageVersionKeys := func(name string, definition templateDefinition) {
		t.Helper()

		if definition.Packages == nil {
			t.Errorf("template %q packages must be an array", name)
			return
		}
		if definition.PackageVersions == nil {
			t.Errorf("template %q package_versions must be an object", name)
			return
		}

		packages := slices.Clone(definition.Packages)
		slices.Sort(packages)
		versionedPackages := slices.Sorted(maps.Keys(definition.PackageVersions))
		if !slices.Equal(packages, versionedPackages) {
			t.Errorf("template %q packages do not match package_versions keys:\npackages         %s\npackage_versions %s", name, prettyJSON(t, packages), prettyJSON(t, versionedPackages))
		}
	}

	checkPackageVersionKeys("default", registry.Default)
	for _, name := range slices.Sorted(maps.Keys(registry.Templates)) {
		checkPackageVersionKeys(name, registry.Templates[name])
	}

	entrypoints := []string{
		"main.tf",
		"providers/do/main.tf",
		"providers/gcp/main.tf",
		"providers/linode/main.tf",
	}
	for _, relativePath := range entrypoints {
		content := readRepositoryFile(t, root, relativePath)
		requireContains(t, content, "if contains(keys(local.template.package_versions), package)", relativePath+" template package-version filter")
		requireContains(t, content, "package_versions = merge(local.template_sitectl_package_versions, local.input_sitectl.package_versions)", relativePath+" explicit package-version override")
		requireContains(t, content, "local.input_sitectl.packages == null ? local.template.packages : local.input_sitectl.packages", relativePath+" omitted-package handling")
	}

	for _, relativePath := range []string{"examples/binpack/main.tf", "docs/examples.md"} {
		content := readRepositoryFile(t, root, relativePath)
		for _, packageName := range []string{"sitectl", "sitectl-wp", "sitectl-drupal"} {
			requireContains(t, content, packageName, relativePath+" bin-pack package")
		}
		requireContains(t, content, `sitectl        = "v1.0.0"`, relativePath+" bin-pack core selector")
		requireContains(t, content, `sitectl-wp     = "v1.0.0"`, relativePath+" bin-pack WordPress selector")
		requireContains(t, content, `sitectl-drupal = "v1.0.0"`, relativePath+" bin-pack Drupal selector")
	}
}
