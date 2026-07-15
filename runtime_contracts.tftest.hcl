mock_provider "cloudinit" {}
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}
mock_provider "time" {}

run "root_rejects_non_gcp_provider_selection" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "digitalocean"
    template       = "wp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
  }

  expect_failures = [var.cloud_provider]
}

run "gcp_vault_auth_default_uses_gcp_iam" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "gcp"
    template       = "wp"
    gcp = {
      project_id = "test-project"
    }
  }

  assert {
    condition     = local.vault.auth_method == "gcp-iam"
    error_message = "The root GCP entrypoint must resolve the automatic Vault method to gcp-iam."
  }
}

run "public_entrypoint_exposes_sitectl_package_versions" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "gcp"
    template       = "isle"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      sitectl = {
        package_versions = {
          sitectl        = "v0.38.0"
          sitectl-drupal = "v0.11.0"
          sitectl-isle   = "v0.12.0"
        }
      }
    }
  }

  assert {
    condition = output.sitectl_package_versions == {
      sitectl        = "v0.38.0"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.12.0"
    }
    error_message = "The public entrypoint must expose the effective selector for every template package."
  }
}

run "public_entrypoint_rejects_reserved_extra_environment" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "gcp"
    template       = "wp"
    gcp = {
      project_id     = "test-project"
      project_number = "123456789"
    }
    runtime = {
      extra_env = {
        DOCKER_COMPOSE_DIR = "/tmp/untrusted"
      }
    }
  }

  expect_failures = [var.runtime]
}

run "public_entrypoint_accepts_direct_cloud_run_proxy_depth" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "gcp"
    template       = "wp"
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
    error_message = "The public entrypoint must accept the proven direct Cloud Run client depth of zero."
  }
}

run "public_entrypoint_rejects_negative_power_button_proxy_depth" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "gcp"
    template       = "wp"
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
