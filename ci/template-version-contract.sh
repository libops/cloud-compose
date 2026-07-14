#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
registry="$repo_root/templates/apps.json"

command -v jq >/dev/null 2>&1 || {
  echo "Missing required command: jq" >&2
  exit 1
}

jq -e '
  .default.package_versions == {
    "sitectl": "v0.39.0"
  } and
  .templates.archivesspace.package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-archivesspace": "v0.6.0"
  } and
  .templates.drupal.package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-drupal": "v0.11.0"
  } and
  .templates.isle.package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-drupal": "v0.11.0",
    "sitectl-isle": "v0.18.0"
  } and
  .templates.ojs.package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-ojs": "v0.6.0"
  } and
  .templates["omeka-classic"].package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-omeka-classic": "v0.6.0"
  } and
  .templates["omeka-s"].package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-omeka-s": "v0.6.0"
  } and
  .templates.wp.package_versions == {
    "sitectl": "v0.39.0",
    "sitectl-wp": "v0.5.0"
  } and
  all([.default, .templates[]][]; (.packages | sort) == (.package_versions | keys | sort))
' "$registry" >/dev/null

for entrypoint in \
  "$repo_root/main.tf" \
  "$repo_root/providers/do/main.tf" \
  "$repo_root/providers/gcp/main.tf" \
  "$repo_root/providers/linode/main.tf"; do
  grep -Fq 'if contains(keys(local.template.package_versions), package)' "$entrypoint" || {
    echo "Template package versions are not filtered in ${entrypoint#"$repo_root"/}" >&2
    exit 1
  }
  grep -Fq 'package_versions = merge(local.template_sitectl_package_versions, local.input_sitectl.package_versions)' "$entrypoint" || {
    echo "Explicit package versions do not override template defaults in ${entrypoint#"$repo_root"/}" >&2
    exit 1
  }
  grep -Fq 'local.input_sitectl.packages == null ? local.template.packages : local.input_sitectl.packages' "$entrypoint" || {
    echo "Template package omission is not distinguished from an explicit package set in ${entrypoint#"$repo_root"/}" >&2
    exit 1
  }
done

echo "Template sitectl package-version contract passed"
