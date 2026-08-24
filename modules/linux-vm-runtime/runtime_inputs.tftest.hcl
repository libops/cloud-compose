mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "4517a8a8a1a40a5e9d3f1ea2b18092216279c2bf85a0e3217486d27753bd0d65\n"
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
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh state") &&
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh status") &&
      strcontains(output.cloud_init, "NOPASSWD:/etc/cloud-compose/bin/cloud-compose-diagnostics.sh dump") &&
      contains(keys(jsondecode(local.rootfs_bundle_content).files), "etc/cloud-compose/bin/cloud-compose-diagnostics.sh") &&
      contains(keys(jsondecode(local.rootfs_bundle_content).files), "etc/cloud-compose/libexec/linux-vm-cloud-init.sh") &&
      contains(keys(jsondecode(local.rootfs_bundle_content).files), "etc/cloud-compose/libexec/bootstrap-sitectl.sh") &&
      contains(keys(jsondecode(local.rootfs_bundle_content).files), "etc/cloud-compose/libexec/install-rootfs.py") &&
      !contains(keys(jsondecode(local.rootfs_bundle_content).files), "home/cloud-compose/prepare-filesystem.sh") &&
      !contains(keys(jsondecode(local.rootfs_bundle_content).files), "home/cloud-compose/persist-filesystems.sh")
    )
    error_message = "Cloud-init must bundle root-owned diagnostics and the sitectl bootstrap with exact passwordless sudo commands."
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

run "renders_bounded_rootfs_bundle" {
  command = plan

  variables {
    name                       = "contract-test"
    provider_name              = "linode"
    region                     = "us-east"
    data_device                = "/dev/test-data"
    volumes_device             = "/dev/test-volumes"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    rootfs                     = "testdata/rootfs"
    offhost_backup_driver_path = "/etc/cloud-compose/libexec/custom-offhost-driver"
  }

  assert {
    condition = (
      strcontains(
        output.cloud_init,
        base64gzip(file("${path.module}/../../rootfs/etc/cloud-compose/libexec/install-rootfs.py")),
      ) &&
      strcontains(output.cloud_init, base64gzip(local.rootfs_bundle_content)) &&
      strcontains(output.cloud_init, "[python3, /var/lib/cloud-compose/bootstrap/install-rootfs.py") &&
      strcontains(output.cloud_init, "[bash, /etc/cloud-compose/libexec/linux-vm-cloud-init.sh")
    )
    error_message = "Linux cloud-init must install the checked rootfs bundle before invoking the stable bootstrap path."
  }

  assert {
    condition = (
      jsondecode(local.rootfs_bundle_content).files["etc/cloud-compose/libexec/custom-offhost-driver"].mode == "0755" &&
      jsondecode(local.rootfs_bundle_content).files["etc/cloud-compose/unrelated-config"].mode == "0644" &&
      jsondecode(local.rootfs_bundle_content).files["etc/cloud-compose/libexec/bootstrap-sitectl.sh"].mode == "0755" &&
      strcontains(file("${path.module}/../../rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh"), "host filesystems") &&
      strcontains(output.cloud_init, module.sitectl_runtime.package_versions["sitectl"])
    )
    error_message = "The rootfs bundle must preserve file modes and invoke the pinned sitectl filesystem runtime."
  }

  assert {
    condition     = length(output.cloud_init) <= 65535
    error_message = "Linux VM cloud-init must stay below the 64 KiB provider limit."
  }
}
