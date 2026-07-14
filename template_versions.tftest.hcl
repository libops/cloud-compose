mock_provider "cloudinit" {}
mock_provider "digitalocean" {}
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}
mock_provider "linode" {}
mock_provider "time" {}

run "template_uses_released_package_set" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "digitalocean"
    template       = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl        = "v0.39.0"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.18.0"
    }
    error_message = "The Isle template must select its reviewed core and plugin release set by default."
  }
}

run "explicit_package_versions_override_template_defaults" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "digitalocean"
    template       = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        package_versions = {
          sitectl      = "v0.40.0"
          sitectl-isle = "v0.19.0"
        }
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl        = "v0.40.0"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.19.0"
    }
    error_message = "Explicit per-package selectors must override only their matching template defaults."
  }
}

run "custom_package_set_filters_template_versions" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "digitalocean"
    template       = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = ["sitectl", "sitectl-wp"]
        package_versions = {
          sitectl-wp = "v0.5.1"
        }
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl    = "v0.39.0"
      sitectl-wp = "v0.5.1"
    }
    error_message = "Template selectors for packages omitted by a custom package set must not reach the runtime."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "digitalocean"
    template       = "isle"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = ["sitectl"]
      }
    }
  }

  assert {
    condition = local.sitectl.packages == tolist(["sitectl"]) && local.sitectl.package_versions == {
      sitectl = "v0.39.0"
    }
    error_message = "An explicit core-only package set must not be mistaken for an omitted template package selection."
  }
}
