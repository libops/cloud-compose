variable "name" {
  type        = string
  description = "Deployment name. Used for the Droplet, volumes, firewall, and default compose project."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,45}$", var.name))
    error_message = "name must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "digitalocean" {
  description = "DigitalOcean infrastructure settings."
  type = object({
    region = optional(string, "tor1")
    tags   = optional(list(string), ["cloud-compose"])

    droplet = optional(object({
      size       = optional(string, "s-2vcpu-4gb")
      image      = optional(string, "ubuntu-24-04-x64")
      ssh_keys   = optional(list(string), [])
      vpc_uuid   = optional(string, null)
      monitoring = optional(bool, true)
      ipv6       = optional(bool, true)
      backups    = optional(bool, false)
    }), {})

    ssh = optional(object({
      cloud_compose_keys = optional(list(string), [])
      users              = optional(map(list(string)), {})
    }), {})

    volumes = optional(object({
      data_size_gb           = optional(number, 50)
      docker_volumes_size_gb = optional(number, 100)
    }), {})

    firewall = optional(object({
      enabled              = optional(bool, true)
      ssh_source_addresses = optional(list(string), ["0.0.0.0/0", "::/0"])
      web_source_addresses = optional(list(string), ["0.0.0.0/0", "::/0"])
    }), {})
  })
  default = {}
}

variable "runtime" {
  description = "Provider-neutral compose/runtime settings."
  type = object({
    rootfs                = optional(string, "")
    rootfs_archive_url    = optional(string, "")
    rootfs_archive_sha256 = optional(string, "")

    compose = optional(object({
      primary      = optional(string, "")
      ingress_port = optional(number, 80)
      ingress = optional(object({
        letsencrypt     = optional(bool, false)
        bot_mitigation  = optional(bool, false)
        mode            = optional(string, "")
        domain          = optional(string, "")
        acme_email      = optional(string, "")
        trusted_ips     = optional(list(string), [])
        max_upload_size = optional(string, "")
        upload_timeout  = optional(string, "")
      }), {})
      repo   = optional(string, "")
      branch = optional(string, "main")
      projects = optional(map(object({
        docker_compose_repo   = string
        docker_compose_branch = optional(string)
        project_dir           = optional(string)
        compose_project_name  = optional(string)
        ingress_port          = optional(number)
        ingress = optional(object({
          letsencrypt     = optional(bool)
          bot_mitigation  = optional(bool)
          mode            = optional(string)
          domain          = optional(string)
          acme_email      = optional(string)
          trusted_ips     = optional(list(string))
          max_upload_size = optional(string)
          upload_timeout  = optional(string)
        }), {})
        sitectl_context_name   = optional(string)
        sitectl_plugin         = optional(string)
        sitectl_environment    = optional(string)
        sitectl_packages       = optional(list(string), [])
        sitectl_verify_args    = optional(list(string), [])
        docker_compose_init    = optional(list(string))
        docker_compose_up      = optional(list(string))
        docker_compose_down    = optional(list(string))
        docker_compose_rollout = optional(list(string))
      })), {})
      init = optional(list(string), [
        "sitectl config set-context \"$${SITECTL_CONTEXT_NAME}\" --type local --project-dir \"$${DOCKER_COMPOSE_DIR}\" --site \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --plugin \"$${SITECTL_PLUGIN}\" --environment \"$${SITECTL_ENVIRONMENT}\" --project-name \"$${CLOUD_COMPOSE_INSTANCE_NAME}\" --compose-project-name \"$${COMPOSE_PROJECT_NAME}\" --docker-socket /var/run/docker.sock --env-file .env --default"
      ])
      up = optional(list(string), [
        "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" up -d --remove-orphans",
        "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\"",
        "if [ \"$${SITECTL_ENVIRONMENT}\" != \"production\" ]; then sitectl verify --context \"$${SITECTL_CONTEXT_NAME}\" $${SITECTL_VERIFY_ARGS:-}; fi"
      ])
      down = optional(list(string), [
        "sitectl compose --context \"$${SITECTL_CONTEXT_NAME}\" down"
      ])
      rollout = optional(list(string), [
        "sitectl deploy --context \"$${SITECTL_CONTEXT_NAME}\" --skip-git",
        "sitectl healthcheck --context \"$${SITECTL_CONTEXT_NAME}\" --persist --timeout \"$${SITECTL_HEALTHCHECK_TIMEOUT}\" --interval \"$${SITECTL_HEALTHCHECK_INTERVAL}\""
      ])
    }), {})

    sitectl = optional(object({
      packages             = optional(list(string), ["sitectl"])
      version              = optional(string, "latest")
      context_name         = optional(string, "")
      plugin               = optional(string, "core")
      environment          = optional(string, "production")
      healthcheck_timeout  = optional(string, "20m")
      healthcheck_interval = optional(string, "15s")
      verify_args          = optional(list(string), [])
    }), {})

    docker = optional(object({
      # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
      compose_version = optional(string, "v5.2.0")
      # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
      buildx_version = optional(string, "v0.35.0")
    }), {})

    managed_runtime = optional(object({
      enabled                       = optional(bool, true)
      internal_services_enabled     = optional(bool, false)
      internal_services_auto_update = optional(bool, false)
      artifacts = optional(list(object({
        name    = string
        url     = string
        sha256  = string
        path    = string
        mode    = optional(string, "0755")
        owner   = optional(string, "root")
        group   = optional(string, "root")
        restart = optional(string, "")
      })), [])
    }), {})

    vault = optional(object({
      addr                    = optional(string, "")
      namespace               = optional(string, "")
      role                    = optional(string, "")
      agent_enabled           = optional(bool, false)
      auth_method             = optional(string, "consumer-managed")
      agent_token_path        = optional(string, "/mnt/disks/data/vault/token")
      agent_additional_config = optional(string, "")
      agent_templates = optional(list(object({
        destination = string
        contents    = string
        perms       = optional(string, "0640")
        command     = optional(string, "")
      })), [])
    }), {})

    extra_env = optional(map(string), {})
  })
  default = {}

  validation {
    condition = alltrue([
      for name, app in var.runtime.compose.projects :
      can(regex("^[a-z][a-z0-9-]*$", name)) &&
      trimspace(app.docker_compose_repo) != "" &&
      try(app.ingress_port, var.runtime.compose.ingress_port) > 0 &&
      try(app.ingress_port, var.runtime.compose.ingress_port) <= 65535
    ])
    error_message = "runtime.compose.projects keys must match ^[a-z][a-z0-9-]*$, docker_compose_repo is required, and ingress_port must be between 1 and 65535."
  }

  validation {
    condition     = contains(["gcp-iam", "consumer-managed"], var.runtime.vault.auth_method)
    error_message = "runtime.vault.auth_method must be gcp-iam or consumer-managed."
  }
}
