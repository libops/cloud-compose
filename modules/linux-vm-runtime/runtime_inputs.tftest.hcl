run "renders_safe_ssh_values" {
  command = plan

  variables {
    name                = "contract-test"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    cloud_compose_ssh_keys = [
      "ssh-ed25519 AAAATEST literal-$(not-a-command)",
    ]
    ssh_users = {
      app_operator = ["ssh-ed25519 AAAAOPERATOR operator@example.org"]
    }
  }

  assert {
    condition     = strcontains(output.cloud_init, jsonencode("ssh-ed25519 AAAATEST literal-$(not-a-command)"))
    error_message = "SSH keys must be YAML encoded as literal values."
  }

  assert {
    condition     = strcontains(output.cloud_init, "name: ${jsonencode("app_operator")}")
    error_message = "SSH usernames must be YAML encoded as literal values."
  }
}

run "normalizes_minimal_compose_project" {
  command = plan

  variables {
    name           = "contract-test"
    provider_name  = "linode"
    region         = "us-east"
    data_device    = "/dev/test-data"
    volumes_device = "/dev/test-volumes"
    compose_projects = {
      wordpress = {
        docker_compose_repo   = "https://github.com/libops/wp.git"
        docker_compose_branch = "v1.0.0"
      }
    }
    sitectl_verify_args = ["--route", "/"]
  }

  assert {
    condition = (
      local.compose_projects.wordpress.name == "wordpress" &&
      local.compose_projects.wordpress.docker_compose_repo == "https://github.com/libops/wp.git" &&
      local.compose_projects.wordpress.docker_compose_branch == "v1.0.0" &&
      local.compose_projects.wordpress.repo_path == "libops/wp.git" &&
      local.compose_projects.wordpress.project_dir == "/mnt/disks/data/libops/wp.git/wordpress" &&
      local.compose_projects.wordpress.compose_project_name == "libops-wp-v1-0-0" &&
      local.compose_projects.wordpress.ingress_port == 80 &&
      local.compose_projects.wordpress.ingress.letsencrypt == var.sitectl_ingress.letsencrypt &&
      local.compose_projects.wordpress.sitectl_context_name == "wordpress" &&
      local.compose_projects.wordpress.sitectl_plugin == "core" &&
      local.compose_projects.wordpress.sitectl_environment == "production" &&
      local.compose_projects.wordpress.sitectl_packages == tolist(["sitectl"]) &&
      local.compose_projects.wordpress.sitectl_verify_args == tolist(["--route", "/"]) &&
      local.compose_projects.wordpress.init_commands == var.docker_compose_init &&
      local.compose_projects.wordpress.up_commands == var.docker_compose_up &&
      local.compose_projects.wordpress.down_commands == var.docker_compose_down &&
      local.compose_projects.wordpress.rollout_commands == var.docker_compose_rollout
    )
    error_message = "A compose project containing only docker_compose_repo must inherit and derive every optional field."
  }
}

run "preserves_explicit_project_directory_during_default_migration" {
  command = plan

  variables {
    name           = "contract-test"
    provider_name  = "linode"
    region         = "us-east"
    data_device    = "/dev/test-data"
    volumes_device = "/dev/test-volumes"
    compose_projects = {
      wordpress = {
        docker_compose_repo   = "https://github.com/libops/wp.git"
        docker_compose_branch = "v1.0.0"
        project_dir           = "/mnt/disks/data/libops/wp.git/v1.0.0"
      }
    }
  }

  assert {
    condition     = local.compose_projects.wordpress.project_dir == "/mnt/disks/data/libops/wp.git/v1.0.0"
    error_message = "An explicit legacy project_dir must remain unchanged while callers migrate to the stable default."
  }
}

run "distinguishes_inherited_and_explicit_core_only_project_packages" {
  command = plan

  variables {
    name           = "contract-test"
    provider_name  = "linode"
    region         = "us-east"
    data_device    = "/dev/test-data"
    volumes_device = "/dev/test-volumes"
    sitectl_packages = [
      "sitectl-drupal",
      "sitectl-isle",
    ]
    compose_projects = {
      inherited = {
        docker_compose_repo = "https://github.com/libops/isle.git"
      }
      core-only = {
        docker_compose_repo = "https://github.com/libops/wp.git"
        sitectl_packages    = []
      }
    }
  }

  assert {
    condition = (
      local.compose_projects.inherited.sitectl_packages == tolist(["sitectl", "sitectl-drupal", "sitectl-isle"]) &&
      local.compose_projects["core-only"].sitectl_packages == tolist(["sitectl"]) &&
      module.sitectl_runtime.packages == tolist(["sitectl", "sitectl-drupal", "sitectl-isle"])
    )
    error_message = "Project manifests must distinguish inherited packages from an explicit list while the host package set remains their union."
  }
}

run "resolves_independent_sitectl_package_versions" {
  command = plan

  variables {
    name                = "contract-test"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/isle.git"
    sitectl_packages    = ["sitectl-drupal", "sitectl-isle"]
    sitectl_version     = "v0.38.0"
    sitectl_package_versions = {
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.12.0"
    }
  }

  assert {
    condition = output.sitectl_package_versions == {
      sitectl        = "v0.38.0"
      sitectl-drupal = "v0.11.0"
      sitectl-isle   = "v0.12.0"
    }
    error_message = "The Linux VM runtime must preserve independent package versions."
  }
}

run "rejects_multiline_cloud_compose_key" {
  command = plan

  variables {
    name                = "contract-test"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    cloud_compose_ssh_keys = [
      "ssh-ed25519 AAAATEST\nruncmd: [touch /tmp/cloud-compose-ssh-injection]",
    ]
  }

  expect_failures = [var.cloud_compose_ssh_keys]
}

run "rejects_unsafe_ssh_username" {
  command = plan

  variables {
    name                = "contract-test"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    ssh_users = {
      "operator\nruncmd" = ["ssh-ed25519 AAAAOPERATOR"]
    }
  }

  expect_failures = [var.ssh_users]
}

run "renders_verified_rootfs_archive" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "https://example.invalid/cloud-compose-$(id).tar.gz"
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition     = strcontains(output.cloud_init, "sha256sum -c -")
    error_message = "Archive cloud-init must verify SHA-256 before extraction."
  }

  assert {
    condition = (
      strcontains(output.cloud_init, "tar -xzf \"$tmp/rootfs.tar.gz\"") &&
      strcontains(output.cloud_init, "install -m 0600 -- \"$filesystem_prep_source\" \"$filesystem_prep\"") &&
      strcontains(output.cloud_init, "bash \"$filesystem_prep\"") &&
      strcontains(output.cloud_init, "bash \"$filesystem_persist\"") &&
      strcontains(output.cloud_init, "cp -a \"$rootfs_dir\"/. /") &&
      length(split("sha256sum -c -", output.cloud_init)[0]) < length(split("tar -xzf \"$tmp/rootfs.tar.gz\"", output.cloud_init)[0]) &&
      length(split("tar -xzf \"$tmp/rootfs.tar.gz\"", output.cloud_init)[0]) < length(split("install -m 0600 -- \"$filesystem_prep_source\" \"$filesystem_prep\"", output.cloud_init)[0]) &&
      length(split("install -m 0600 -- \"$filesystem_prep_source\" \"$filesystem_prep\"", output.cloud_init)[0]) < length(split("bash \"$filesystem_prep\"", output.cloud_init)[0]) &&
      length(split("bash \"$filesystem_persist\"", output.cloud_init)[0]) < length(split("cp -a \"$rootfs_dir\"/. /", output.cloud_init)[0])
    )
    error_message = "Archive cloud-init must verify and extract before loading its helpers, then install the rootfs only after filesystem preparation and persistence."
  }

  assert {
    condition = (
      !strcontains(output.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/prepare-filesystem.sh")) &&
      !strcontains(output.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/persist-filesystems.sh"))
    )
    error_message = "Archive-backed cloud-init must not embed the filesystem helper payloads."
  }

  assert {
    condition = (
      strcontains(output.cloud_init, "verified rootfs archive is missing filesystem preparation scripts") &&
      strcontains(output.cloud_init, "verified rootfs directory is unavailable during installation")
    )
    error_message = "Archive-backed cloud-init must fail closed when the verified rootfs or its filesystem helpers are missing."
  }

  assert {
    condition = (
      strcontains(output.cloud_init, "archive_url_b64=") &&
      !strcontains(output.cloud_init, "$(id)")
    )
    error_message = "Archive URLs must be rendered as base64 data rather than executable shell syntax."
  }
}

run "embeds_filesystem_helpers_without_archive" {
  command = plan

  variables {
    name                = "contract-test"
    provider_name       = "digitalocean"
    region              = "nyc3"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
  }

  assert {
    condition = (
      strcontains(output.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/prepare-filesystem.sh")) &&
      strcontains(output.cloud_init, filebase64("${path.module}/../../rootfs/home/cloud-compose/persist-filesystems.sh")) &&
      !strcontains(output.cloud_init, "archive_url_b64=")
    )
    error_message = "Inline cloud-init must retain the embedded filesystem-helper bootstrap when no archive is configured."
  }
}

run "rejects_rootfs_archive_without_checksum" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
    rootfs_archive_sha256 = ""
  }

  expect_failures = [output.cloud_init]
}

run "rejects_non_https_rootfs_archive" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "http://example.invalid/cloud-compose.tar.gz"
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.rootfs_archive_url]
}

run "rejects_rootfs_checksum_without_archive" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = ""
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [output.cloud_init]
}

run "rejects_malformed_rootfs_checksum" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "https://example.invalid/cloud-compose.tar.gz"
    rootfs_archive_sha256 = "not-a-sha256"
  }

  expect_failures = [output.cloud_init]
}
