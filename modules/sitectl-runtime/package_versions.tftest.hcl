run "resolves_independent_package_versions" {
  command = plan

  variables {
    packages         = ["sitectl-isle", "sitectl-drupal"]
    fallback_version = "v0.38.0"
    package_versions = {
      sitectl        = "v0.39.0-rc.1"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.12.0"
    }
  }

  assert {
    condition = output.package_versions == {
      sitectl        = "v0.39.0-rc.1"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.12.0"
    }
    error_message = "Each package override must resolve independently."
  }
}

run "preserves_legacy_version_fallback" {
  command = plan

  variables {
    packages         = ["sitectl-isle"]
    fallback_version = "v0.38.0"
    package_versions = {}
  }

  assert {
    condition = output.package_versions == {
      sitectl      = "v0.38.0"
      sitectl-isle = "v0.38.0"
    }
    error_message = "An empty package_versions map must preserve the legacy all-packages version behavior."
  }
}

run "uses_fallback_for_unlisted_package" {
  command = plan

  variables {
    packages         = ["sitectl-isle"]
    fallback_version = "latest"
    package_versions = {
      sitectl = "v0.38.0"
    }
  }

  assert {
    condition = output.package_versions == {
      sitectl      = "v0.38.0"
      sitectl-isle = "latest"
    }
    error_message = "Packages without an override must use the legacy version fallback."
  }
}

run "rejects_unknown_package_override" {
  command = plan

  variables {
    packages = ["sitectl-isle"]
    package_versions = {
      sitectl-wp = "v0.9.0"
    }
  }

  expect_failures = [output.package_versions]
}

run "rejects_invalid_package_name" {
  command = plan

  variables {
    packages = ["../../sitectl"]
  }

  expect_failures = [var.packages]
}

run "rejects_trailing_version_data" {
  command = plan

  variables {
    fallback_version = "v0.38.0/../../latest"
  }

  expect_failures = [var.fallback_version]
}
