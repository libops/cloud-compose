mock_provider "digitalocean" {}

run "custom_package_set_merges_only_applicable_template_versions" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = ["sitectl", "sitectl-wp"]
        package_versions = {
          sitectl    = "v0.40.0"
          sitectl-wp = "v0.5.1"
        }
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.package_versions == {
      sitectl    = "v0.40.0"
      sitectl-wp = "v0.5.1"
    }
    error_message = "The DigitalOcean entrypoint must filter template selectors and preserve explicit overrides."
  }

  assert {
    condition     = local.runtime.compose.branch == "v1.1.0"
    error_message = "The DigitalOcean entrypoint must inherit the ISLE v1.1.0 template branch when no override is supplied."
  }

  assert {
    condition     = local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    error_message = "The DigitalOcean ISLE preset must supply its required application environment."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = []
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.packages == tolist(["sitectl"]) && local.runtime.sitectl.package_versions == {
      sitectl = "v1.0.0"
    }
    error_message = "The DigitalOcean entrypoint must preserve an explicit core-only package set."
  }
}
