mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "fb6105bfdc7ecf37c7eb84cf5de7c4c513dd7a3087b40742cd7fe0dab18fe255\n"
      status_code   = 200
    }
  }
}

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

  assert {
    condition = (
      strcontains(output.cloud_init, "path: \"/etc/cloud-compose/bin/cloud-compose-diagnostics.sh\"") &&
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh state") &&
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh status") &&
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh dump") &&
      strcontains(
        local.write_files_content,
        "- path: \"/etc/cloud-compose/libexec/linux-vm-cloud-init.sh\"",
      )
    )
    error_message = "Cloud-init must install one root-owned diagnostics program with exact passwordless sudo commands."
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
        ingress_port        = 81
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
    name                       = "contract-test"
    provider_name              = "linode"
    region                     = "us-east"
    data_device                = "/dev/test-data"
    volumes_device             = "/dev/test-volumes"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    rootfs                     = "testdata/rootfs"
    rootfs_archive_url         = "https://example.invalid/cloud-compose-$(id).tar.gz"
    rootfs_archive_sha256      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    offhost_backup_driver_path = "/etc/cloud-compose/libexec/custom-offhost-driver"
  }

  assert {
    condition = (
      strcontains(
        output.cloud_init,
        base64gzip(file("${path.module}/../../rootfs/etc/cloud-compose/libexec/rootfs-archive.sh")),
      ) &&
      length(data.http.rootfs_contract) == 1 &&
      strcontains(output.cloud_init, local.rootfs_contract_sha256) &&
      data.http.rootfs_contract[0].url == "https://example.invalid/cloud-compose-rootfs.contract.sha256" &&
      strcontains(output.cloud_init, "[bash, /var/lib/cloud-compose/bootstrap/rootfs-archive.sh, prepare-linux") &&
      strcontains(output.cloud_init, "[bash, /var/lib/cloud-compose/bootstrap/linux-vm-cloud-init.sh")
    )
    error_message = "Archive-mode Linux cloud-init must transfer compressed checked bootstrap programs, bind the archive to the exact module rootfs, and invoke stable paths."
  }

  assert {
    condition = (
      !strcontains(
        local.write_files_content,
        base64gzip(file("${path.module}/../../rootfs/home/cloud-compose/prepare-filesystem.sh")),
      ) &&
      !strcontains(
        local.write_files_content,
        base64gzip(file("${path.module}/../../rootfs/home/cloud-compose/persist-filesystems.sh")),
      )
    )
    error_message = "Archive-backed cloud-init must not embed the filesystem helper payloads."
  }

  assert {
    condition = (
      strcontains(output.cloud_init, base64encode(var.rootfs_archive_url)) &&
      !strcontains(output.cloud_init, var.rootfs_archive_url)
    )
    error_message = "Archive URLs must be rendered as base64 data rather than executable shell syntax."
  }

  assert {
    condition = (
      local.rootfs_file_permissions["etc/cloud-compose/libexec/custom-offhost-driver"] == "0755" &&
      local.rootfs_file_permissions["etc/cloud-compose/unrelated-config"] == "0644" &&
      strcontains(
        local.write_files_content,
        "- path: \"/var/lib/cloud-compose/rootfs-overlay/etc/cloud-compose/libexec/custom-offhost-driver\"\n  owner: \"root:root\"\n  permissions: \"0755\"",
      ) &&
      strcontains(
        local.write_files_content,
        "- path: \"/var/lib/cloud-compose/rootfs-overlay/etc/cloud-compose/unrelated-config\"\n  owner: \"root:root\"\n  permissions: \"0644\"",
      )
    )
    error_message = "Archive-backed Linux VM overlays must make only the configured off-host backup driver executable."
  }
}

run "renders_exact_current_source_archive_for_hosted_smoke" {
  command = plan

  variables {
    name                              = "contract-test"
    provider_name                     = "linode"
    region                            = "us-east"
    data_device                       = "/dev/test-data"
    volumes_device                    = "/dev/test-volumes"
    docker_compose_repo               = "https://github.com/libops/wp.git"
    rootfs_archive_url                = "https://github.com/libops/cloud-compose/archive/1111111111111111111111111111111111111111.tar.gz"
    rootfs_archive_sha256             = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rootfs_test_source_archive_prefix = "cloud-compose-1111111111111111111111111111111111111111"
  }

  assert {
    condition = (
      length(data.http.rootfs_contract) == 0 &&
      strcontains(output.cloud_init, "prepare-linux-test-source") &&
      strcontains(output.cloud_init, jsonencode(var.rootfs_test_source_archive_prefix)) &&
      strcontains(output.cloud_init, local.rootfs_contract_sha256)
    )
    error_message = "Hosted smoke source-archive mode must skip the unavailable release sidecar while binding the exact source rootfs to this module contract."
  }
}

run "rejects_source_archive_from_another_commit" {
  command = plan

  variables {
    name                              = "contract-test"
    provider_name                     = "linode"
    region                            = "us-east"
    data_device                       = "/dev/test-data"
    volumes_device                    = "/dev/test-volumes"
    docker_compose_repo               = "https://github.com/libops/wp.git"
    rootfs_archive_url                = "https://github.com/libops/cloud-compose/archive/2222222222222222222222222222222222222222.tar.gz"
    rootfs_archive_sha256             = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rootfs_test_source_archive_prefix = "cloud-compose-1111111111111111111111111111111111111111"
  }

  expect_failures = [output.cloud_init]
}

run "rejects_tag_named_source_archive_prefix" {
  command = plan

  variables {
    name                              = "contract-test"
    provider_name                     = "linode"
    region                            = "us-east"
    data_device                       = "/dev/test-data"
    volumes_device                    = "/dev/test-volumes"
    docker_compose_repo               = "https://github.com/libops/wp.git"
    rootfs_archive_url                = "https://github.com/libops/cloud-compose/archive/refs/tags/v1.2.3.tar.gz"
    rootfs_archive_sha256             = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rootfs_test_source_archive_prefix = "cloud-compose-v1.2.3"
  }

  expect_failures = [var.rootfs_test_source_archive_prefix]
}

run "rejects_arbitrary_test_source_archive_url" {
  command = plan

  variables {
    name                              = "contract-test"
    provider_name                     = "linode"
    region                            = "us-east"
    data_device                       = "/dev/test-data"
    volumes_device                    = "/dev/test-volumes"
    docker_compose_repo               = "https://github.com/libops/wp.git"
    rootfs_archive_url                = "https://example.invalid/1111111111111111111111111111111111111111.tar.gz"
    rootfs_archive_sha256             = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    rootfs_test_source_archive_prefix = "cloud-compose-1111111111111111111111111111111111111111"
  }

  expect_failures = [output.cloud_init]
}

run "rejects_rootfs_release_from_another_module_version" {
  command = plan

  variables {
    name                  = "contract-test"
    provider_name         = "linode"
    region                = "us-east"
    data_device           = "/dev/test-data"
    volumes_device        = "/dev/test-volumes"
    docker_compose_repo   = "https://github.com/libops/wp.git"
    rootfs_archive_url    = "https://example.invalid/cloud-compose-rootfs.tar.gz"
    rootfs_archive_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  override_data {
    target = data.http.rootfs_contract[0]
    values = {
      response_body = "0000000000000000000000000000000000000000000000000000000000000000\n"
      status_code   = 200
    }
  }

  expect_failures = [data.http.rootfs_contract[0]]
}

run "embeds_filesystem_helpers_without_archive" {
  command = plan

  variables {
    name                       = "contract-test"
    provider_name              = "digitalocean"
    region                     = "nyc3"
    data_device                = "/dev/test-data"
    volumes_device             = "/dev/test-volumes"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    rootfs                     = "testdata/rootfs"
    offhost_backup_driver_path = "/etc/cloud-compose/libexec/custom-offhost-driver"
  }

  assert {
    condition = (
      strcontains(
        local.write_files_content,
        base64gzip(file("${path.module}/../../rootfs/home/cloud-compose/prepare-filesystem.sh")),
      ) &&
      strcontains(
        local.write_files_content,
        base64gzip(file("${path.module}/../../rootfs/home/cloud-compose/persist-filesystems.sh")),
      ) &&
      !strcontains(local.write_files_content, "/var/lib/cloud-compose/rootfs-overlay/")
    )
    error_message = "Non-archive cloud-init must transfer the checked-in filesystem helpers without using the archive overlay."
  }

  assert {
    condition = (
      local.rootfs_file_permissions["etc/cloud-compose/libexec/custom-offhost-driver"] == "0755" &&
      local.rootfs_file_permissions["etc/cloud-compose/unrelated-config"] == "0644" &&
      strcontains(
        local.write_files_content,
        "- path: \"/etc/cloud-compose/libexec/custom-offhost-driver\"\n  owner: \"root:root\"\n  permissions: \"0755\"",
      ) &&
      strcontains(
        local.write_files_content,
        "- path: \"/etc/cloud-compose/unrelated-config\"\n  owner: \"root:root\"\n  permissions: \"0644\"",
      )
    )
    error_message = "Embedded Linux VM overlays must make only the configured off-host backup driver executable."
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
