mock_provider "digitalocean" {}

run "custom_package_set_merges_only_applicable_template_versions" {
  command = plan

  override_data {
    target = module.digitalocean.module.runtime.data.http.rootfs_contract[0]
    values = {
      response_body = "a0f4dac5a536d8e61c7367170b7afc2689838c4e3bf155b1cde2fe17032c06db\n"
      status_code   = 200
    }
  }

  variables {
    name     = "template-versions"
    template = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose-rootfs.tar.gz"
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
    condition     = local.runtime.compose.branch == "v1.3.1"
    error_message = "The DigitalOcean entrypoint must inherit the ISLE v1.3.1 template branch when no override is supplied."
  }

  assert {
    condition     = local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    error_message = "The DigitalOcean ISLE preset must supply its required application environment."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  override_data {
    target = module.digitalocean.module.runtime.data.http.rootfs_contract[0]
    values = {
      response_body = "a0f4dac5a536d8e61c7367170b7afc2689838c4e3bf155b1cde2fe17032c06db\n"
      status_code   = 200
    }
  }

  variables {
    name     = "template-versions"
    template = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose-rootfs.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = []
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.packages == tolist(["sitectl"]) && local.runtime.sitectl.package_versions == {
      sitectl = "v1.9.1"
    }
    error_message = "The DigitalOcean entrypoint must preserve an explicit core-only package set."
  }
}
