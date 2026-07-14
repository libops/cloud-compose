run "allows_application_tuning_environment" {
  command = plan

  variables {
    name                = "extra-env-contract"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    extra_env = {
      NGINX_CLIENT_MAX_BODY_SIZE = "512m"
      PHP_UPLOAD_MAX_FILESIZE    = "512M"
      BASH_ENV                   = "/tmp/application-only-bash-env"
      LD_PRELOAD                 = "/tmp/application-only-preload.so"
    }
  }

  assert {
    condition = (
      !strcontains(module.runtime_env.content, "NGINX_CLIENT_MAX_BODY_SIZE") &&
      !strcontains(module.runtime_env.content, "PHP_UPLOAD_MAX_FILESIZE") &&
      !contains(keys(local.host_env), "BASH_ENV") &&
      !contains(keys(local.host_env), "LD_PRELOAD") &&
      strcontains(
        local.application_env_file_content,
        jsonencode(base64gzip(jsonencode(var.extra_env))),
      )
    )
    error_message = "Application tuning must be serialized as data without entering the host process environment."
  }
}

run "rejects_reserved_environment_prefix" {
  command = plan

  variables {
    name                = "extra-env-contract"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    extra_env = {
      SITECTL_PACKAGE_VERSIONS = "{}"
    }
  }

  expect_failures = [var.extra_env]
}

run "rejects_reserved_environment_name" {
  command = plan

  variables {
    name                = "extra-env-contract"
    provider_name       = "linode"
    region              = "us-east"
    data_device         = "/dev/test-data"
    volumes_device      = "/dev/test-volumes"
    docker_compose_repo = "https://github.com/libops/wp.git"
    extra_env = {
      PATH = "/tmp/untrusted"
    }
  }

  expect_failures = [var.extra_env]
}
