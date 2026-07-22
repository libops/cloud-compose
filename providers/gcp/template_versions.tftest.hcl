mock_provider "cloudinit" {}
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}
mock_provider "time" {}

run "custom_package_set_merges_only_applicable_template_versions" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
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
    error_message = "The GCP entrypoint must filter template selectors and preserve explicit overrides."
  }

  assert {
    condition     = local.runtime.compose.branch == "v1.1.0"
    error_message = "The GCP entrypoint must inherit the ISLE v1.1.0 template branch when no override is supplied."
  }

  assert {
    condition     = local.runtime.extra_env.ISLANDORA_TAG == "6.3.19"
    error_message = "The GCP ISLE preset must supply its required application environment."
  }
}

run "explicit_core_only_package_set_disables_template_plugins" {
  command = plan

  variables {
    name     = "template-versions"
    template = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      sitectl = {
        packages = []
      }
    }
  }

  assert {
    condition = local.runtime.sitectl.packages == tolist(["sitectl"]) && local.runtime.sitectl.package_versions == {
      sitectl = "v1.0.0"
    }
    error_message = "The GCP entrypoint must preserve an explicit core-only package set."
  }
}

run "gcp_entrypoint_forwards_application_data_size" {
  command = plan

  variables {
    name     = "template-versions"
    template = "wp"
    gcp = {
      project_id = "test-project"
      disks = {
        data_size_gb           = 170
        docker_volumes_size_gb = 50
      }
    }
  }

  assert {
    condition = (
      output.volumes.data.size_gb == 170 &&
      output.volumes.docker_volumes.size_gb == 50
    )
    error_message = "The GCP entrypoint must forward independent application-data and Docker-volume sizes."
  }
}

run "accepts_direct_cloud_run_proxy_depth" {
  command = plan

  variables {
    name     = "template-versions"
    template = "wp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
      network = {
        power_button_ip_depth = 0
      }
    }
  }

  assert {
    condition     = local.gcp_network.power_button_ip_depth == 0
    error_message = "The direct public Cloud Run path must accept the proven right-edge client depth of zero."
  }
}

run "rejects_negative_power_button_proxy_depth" {
  command = plan

  variables {
    name     = "template-versions"
    template = "wp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
      network = {
        power_button_ip_depth = -1
      }
    }
  }

  expect_failures = [var.gcp]
}
