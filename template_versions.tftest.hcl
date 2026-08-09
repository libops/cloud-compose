mock_provider "cloudinit" {}
mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "8cc800954d4780c933ebd680b25ec7dacfb61a733b9295f272ab56ac8fbf6b74\n"
      status_code   = 200
    }
  }
}
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
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl = "v1.8.2"
    }
    error_message = "The default template must select the released sitectl v1 core."
  }

  assert {
    condition     = local.compose.branch == "main"
    error_message = "The no-preset path must retain the registry's main branch fallback."
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
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl    = "v1.8.2"
      sitectl-wp = "v2.0.0"
    }
    error_message = "Non-ISLE templates must select their coordinated sitectl v1 release set."
  }

  assert {
    condition     = local.compose.branch == "v1.1.0"
    error_message = "The WordPress preset must select its stable v1.1.0 template contract."
  }
}

run "isle_template_uses_v1_release_set" {
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
    }
  }

  assert {
    condition = local.sitectl.package_versions == {
      sitectl        = "v1.8.2"
      sitectl-drupal = "v1.3.0"
      sitectl-isle   = "v1.5.0"
    }
    error_message = "The ISLE template must select its coordinated sitectl v1 release set by default."
  }

  assert {
    condition     = local.compose.branch == "v1.3.0"
    error_message = "The ISLE preset must select the stable v1.3.0 template contract."
  }

  assert {
    condition = (
      length(keys(local.runtime.extra_env)) == 1 &&
      local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    )
    error_message = "The ISLE preset must supply the minimum supported Islandora image tag."
  }
}

run "explicit_application_environment_overrides_template_defaults" {
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
      extra_env = {
        ISLANDORA_TAG = "6.3.20"
        SITE_LABEL    = "repository"
      }
    }
  }

  assert {
    condition = (
      length(keys(local.runtime.extra_env)) == 2 &&
      local.runtime.extra_env.ISLANDORA_TAG == "6.3.20" &&
      local.runtime.extra_env.SITE_LABEL == "repository"
    )
    error_message = "Explicit application environment must override preset defaults without dropping additional values."
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
      sitectl-drupal = "v1.3.0"
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
      sitectl    = "v1.8.2"
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
      sitectl = {
        packages = ["sitectl"]
      }
    }
  }

  assert {
    condition = local.sitectl.packages == tolist(["sitectl"]) && local.sitectl.package_versions == {
      sitectl = "v1.8.2"
    }
    error_message = "An explicit core-only package set must not be mistaken for an omitted template package selection."
  }
}
