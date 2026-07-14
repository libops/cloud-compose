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

run "provider_neutral_vault_auth_defaults_follow_provider" {
  command = plan

  variables {
    name           = "root-contract"
    cloud_provider = "digitalocean"
    template       = "wp"
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }

  assert {
    condition     = local.vault.auth_method == "consumer-managed"
    error_message = "The provider-neutral Vault default must resolve to consumer-managed outside GCP."
  }
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
    error_message = "The provider-neutral Vault default must resolve to gcp-iam on GCP."
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
