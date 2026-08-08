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
	ExtraEnv        map[string]string `json:"extra_env"`
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
			"sitectl": "v1.8.2",
		},
		"archivesspace": {
			"sitectl":               "v1.8.2",
			"sitectl-archivesspace": "v2.0.0",
		},
		"drupal": {
			"sitectl":        "v1.8.2",
			"sitectl-drupal": "v1.3.0",
		},
		"isle": {
			"sitectl":        "v1.8.2",
			"sitectl-drupal": "v1.3.0",
			"sitectl-isle":   "v1.5.0",
		},
		"ojs": {
			"sitectl":     "v1.8.2",
			"sitectl-ojs": "v1.2.0",
		},
		"omeka-classic": {
			"sitectl":               "v1.8.2",
			"sitectl-omeka-classic": "v1.2.0",
		},
		"omeka-s": {
			"sitectl":         "v1.8.2",
			"sitectl-omeka-s": "v1.2.0",
		},
		"wp": {
			"sitectl":    "v1.8.2",
			"sitectl-wp": "v2.0.0",
		},
	}
	expectedBranches := map[string]string{
		"archivesspace": "v1.0.0",
		"drupal":        "v1.1.0",
		"isle":          "v1.3.0",
		"ojs":           "v1.0.0",
		"omeka-classic": "v1.0.0",
		"omeka-s":       "v1.0.0",
		"wp":            "v1.1.0",
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
		expectedBranch := expectedBranches[name]
		if definition.Branch != expectedBranch {
			t.Errorf("template %q branch = %q, want stable contract %s", name, definition.Branch, expectedBranch)
		}
		expectedExtraEnv := map[string]string{}
		if name == "isle" {
			expectedExtraEnv["ISLANDORA_TAG"] = "6.3.19"
		}
		if !maps.Equal(definition.ExtraEnv, expectedExtraEnv) {
			t.Errorf("template %q application environment diverged:\nexpected %s\nactual   %s", name, prettyJSON(t, expectedExtraEnv), prettyJSON(t, definition.ExtraEnv))
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
		requireContains(t, content, "extra_env = merge(try(local.template.extra_env, {}), var.runtime.extra_env)", relativePath+" template application environment merge")
	}

	for _, relativePath := range []string{"examples/binpack/main.tf", "docs/examples.md"} {
		content := readRepositoryFile(t, root, relativePath)
		for _, packageName := range []string{"sitectl", "sitectl-wp", "sitectl-drupal"} {
			requireContains(t, content, packageName, relativePath+" bin-pack package")
		}
		requireContains(t, content, `sitectl        = "v1.8.2"`, relativePath+" bin-pack core selector")
		requireContains(t, content, `sitectl-wp     = "v2.0.0"`, relativePath+" bin-pack WordPress selector")
		requireContains(t, content, `sitectl-drupal = "v1.3.0"`, relativePath+" bin-pack Drupal selector")
	}
}
