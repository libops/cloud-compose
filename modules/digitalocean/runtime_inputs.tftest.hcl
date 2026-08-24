mock_provider "digitalocean" {}
mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "c33470299657aca69837d7ce2cee73659aa5fd9a3297dcaad4444b50b54cdde2\n"
      status_code   = 200
    }
  }
}

run "merges_provider_neutral_and_provider_specific_ssh_users" {
  command = plan

  variables {
    name = "do-contract"
    digitalocean = {
      ssh = {
        users = {
          shared        = ["ssh-ed25519 AAAAPROVIDER"]
          provider-only = ["ssh-ed25519 AAAADO"]
        }
      }
    }
    runtime = {
      users = {
        shared       = ["ssh-ed25519 AAAARUNTIME"]
        runtime-only = ["ssh-ed25519 AAAANEUTRAL"]
      }
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  assert {
    condition = (
      strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAAPROVIDER") &&
      strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAADO") &&
      strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAANEUTRAL") &&
      !strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAARUNTIME")
    )
    error_message = "Provider-specific SSH users must override matching provider-neutral users while preserving distinct entries."
  }
}

run "exposes_independent_sitectl_package_versions" {
  command = plan

  variables {
    name = "do-contract"
    runtime = {
      compose = {
        repo = "https://github.com/libops/isle.git"
      }
      sitectl = {
        packages = ["sitectl-drupal", "sitectl-isle"]
        version  = "v0.38.0"
        package_versions = {
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
    error_message = "The DigitalOcean module must expose the effective version selector for every package."
  }
}

run "rejects_reserved_extra_environment" {
  command = plan

  variables {
    name = "do-contract"
    runtime = {
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
      extra_env = {
        CLOUD_COMPOSE_PROVIDER = "gcp"
      }
    }
  }

  expect_failures = [var.runtime]
}
