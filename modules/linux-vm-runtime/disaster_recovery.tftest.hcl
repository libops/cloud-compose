run "renders_provider_neutral_disaster_recovery_controls" {
  command = plan

  variables {
    name                       = "contract-test"
    provider_name              = "linode"
    region                     = "us-east"
    data_device                = "/dev/test-data"
    volumes_device             = "/dev/test-volumes"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    offhost_backup_required    = true
    offhost_backup_driver_path = "/usr/local/libexec/cloud-compose/acme-offhost"
  }

  assert {
    condition = (
      local.host_env.CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED == "true" &&
      local.host_env.CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER == "/usr/local/libexec/cloud-compose/acme-offhost"
    )
    error_message = "The Linux VM runtime must render only the required switch and operator-owned driver path."
  }

  assert {
    condition = (
      !strcontains(module.runtime_env.content, "ACCESS_KEY") &&
      !strcontains(module.runtime_env.content, "SECRET_KEY") &&
      !strcontains(module.runtime_env.content, "BUCKET")
    )
    error_message = "The provider-neutral DR contract must not render storage credentials or a storage-vendor destination."
  }
}

run "rejects_unsafe_disaster_recovery_driver_path" {
  command = plan

  variables {
    name                       = "contract-test"
    provider_name              = "linode"
    region                     = "us-east"
    data_device                = "/dev/test-data"
    volumes_device             = "/dev/test-volumes"
    docker_compose_repo        = "https://github.com/libops/wp.git"
    offhost_backup_required    = true
    offhost_backup_driver_path = "/usr/local/libexec/cloud-compose/../untrusted"
  }

  expect_failures = [var.offhost_backup_driver_path]
}
