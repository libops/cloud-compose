mock_provider "cloudinit" {}
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}
mock_provider "time" {}

run "default_template_uses_v1_core" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl = "v1.0.0"
    }
    error_message = "The default template must select the released sitectl v1 core."
  }
}

run "non_isle_template_uses_v1_release_set" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    template       = "wp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl    = "v1.0.0"
      sitectl-wp = "v1.0.0"
    }
    error_message = "Non-ISLE templates must select their coordinated sitectl v1 release set."
  }
}

run "isle_template_uses_released_pre_v1_package_set" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    template       = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl        = "v0.40.0"
      sitectl-drupal = "v0.12.0"
      sitectl-isle   = "v0.19.0"
    }
    error_message = "The Isle template must select its reviewed core and plugin release set by default."
  }
}

run "explicit_package_versions_override_template_defaults" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    template       = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        package_versions = {
          sitectl      = "v0.40.1"
          sitectl-isle = "v0.19.1"
        }
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl        = "v0.40.1"
      sitectl-drupal = "v0.12.0"
      sitectl-isle   = "v0.19.1"
    }
    error_message = "Explicit per-package selectors must override only their matching template defaults."
  }
}

run "custom_package_set_filters_template_versions" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    template       = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      sitectl = {
        packages = ["sitectl", "sitectl-wp"]
        package_versions = {
          sitectl-wp = "v0.6.1"
        }
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl    = "v0.40.0"
      sitectl-wp = "v0.6.1"
    }
    error_message = "Template selectors for packages omitted by a custom package set must not reach the runtime."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  variables {
    name           = "template-versions"
    cloud_provider = "gcp"
    template       = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
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
      sitectl = "v0.40.0"
    }
    error_message = "An explicit core-only package set must not be mistaken for an omitted template package selection."
  }
}
