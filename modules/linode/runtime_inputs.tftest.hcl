mock_provider "linode" {}

run "merges_provider_neutral_and_provider_specific_ssh_users" {
  command = plan

  variables {
    name = "contract-test"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAAINSTANCE"]
      }
      ssh = {
        users = {
          shared        = ["ssh-ed25519 AAAAPROVIDER"]
          provider-only = ["ssh-ed25519 AAAALINODE"]
        }
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
      strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAALINODE") &&
      strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAANEUTRAL") &&
      !strcontains(module.runtime.cloud_init, "ssh-ed25519 AAAARUNTIME")
    )
    error_message = "Provider-specific SSH users must override matching provider-neutral users while preserving distinct entries."
  }
}

run "rejects_multiline_authorized_key" {
  command = plan

  variables {
    name = "contract-test"
    linode = {
      instance = {
        authorized_keys = [
          "ssh-ed25519 AAAATEST\nruncmd: [touch /tmp/cloud-compose-linode-key-injection]",
        ]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  expect_failures = [var.linode]
}

run "rejects_unsafe_authorized_username" {
  command = plan

  variables {
    name = "contract-test"
    linode = {
      instance = {
        authorized_users = ["operator\nruncmd"]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  expect_failures = [var.linode]
}

run "rejects_archive_without_checksum" {
  command = plan

  variables {
    name = "contract-test"
    runtime = {
      rootfs_archive_url = "https://example.invalid/cloud-compose.tar.gz"
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
    }
  }

  expect_failures = [var.runtime]
}

run "exposes_independent_sitectl_package_versions" {
  command = plan

  variables {
    name = "contract-test"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAATEST"]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
    error_message = "The Linode module must expose the effective version selector for every package."
  }
}

run "rejects_reserved_extra_environment" {
  command = plan

  variables {
    name = "contract-test"
    linode = {
      instance = {
        authorized_keys = ["ssh-ed25519 AAAATEST"]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      compose = {
        repo = "https://github.com/libops/wp.git"
      }
      extra_env = {
        LIBOPS_INTERNAL_SERVICES_ENABLED = "true"
      }
    }
  }

  expect_failures = [var.runtime]
}

run "archive_bootstrap_fits_linode_metadata_limit" {
  command = plan

  variables {
    name = "cc-ln-wp-29209714811-a1b2c3"
    linode = {
      instance = {
        authorized_keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuUgUvvcJyWVZkgLrBGGI9RfcNmQsw32QNftNS5/Iiv operator@example.org",
        ]
      }
      ssh = {
        cloud_compose_keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuUgUvvcJyWVZkgLrBGGI9RfcNmQsw32QNftNS5/Iiv operator@example.org",
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyCloudComposeKey smoke@example.org",
        ]
      }
    }
    runtime = {
      rootfs_archive_url    = "https://github.com/libops/cloud-compose/releases/download/1.0.0/cloud-compose-rootfs.tar.gz"
      rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      compose = {
        repo         = "https://github.com/libops/wp.git"
        branch       = "main"
        ingress_port = 80
        ingress = {
          mode        = "http"
          trusted_ips = ["198.51.100.0/24", "2001:db8::/32"]
        }
      }
      sitectl = {
        packages = ["sitectl", "sitectl-wp"]
        version  = "v0.39.0"
        package_versions = {
          sitectl    = "v0.39.0"
          sitectl-wp = "v0.5.0"
        }
        plugin      = "wp"
        environment = "smoke"
      }
      managed_runtime = {
        enabled                       = true
        internal_services_enabled     = false
        internal_services_auto_update = false
      }
    }
  }

  assert {
    condition     = length(base64gzip(module.runtime.cloud_init)) <= 16384
    error_message = "A realistic archive-backed Linode bootstrap must fit within the 16 KiB encoded metadata limit."
  }

  assert {
    condition = (
      !strcontains(module.runtime.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/prepare-filesystem.sh")) &&
      !strcontains(module.runtime.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/persist-filesystems.sh"))
    )
    error_message = "The realistic Linode bootstrap must not regain embedded filesystem helper payloads."
  }
}
