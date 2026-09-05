variable "name" {
  type        = string
  description = "Deployment name. Used for the Linode, volumes, firewall, and default compose project."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,45}$", var.name))
    error_message = "name must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "linode" {
  description = "Linode infrastructure settings. instance.backups_enabled covers only the instance disk; attached application and Docker Block Storage volumes require a separate offsite backup policy."
  type = object({
    region = optional(string, "us-east")
    tags   = optional(list(string), ["cloud-compose"])

    instance = optional(object({
      type             = optional(string, "g6-standard-2")
      image            = optional(string, "linode/ubuntu22.04")
      authorized_keys  = optional(list(string), [])
      authorized_users = optional(list(string), [])
      root_pass        = optional(string, null)
      private_ip       = optional(bool, true)
      backups_enabled  = optional(bool, false)
      watchdog_enabled = optional(bool, true)
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
      enabled         = optional(bool, true)
      ssh_source_ipv4 = optional(list(string), ["0.0.0.0/0"])
      ssh_source_ipv6 = optional(list(string), ["::/0"])
      web_source_ipv4 = optional(list(string), ["0.0.0.0/0"])
      web_source_ipv6 = optional(list(string), ["::/0"])
    }), {})

    rollout = optional(object({
      enabled        = optional(bool, false)
      release_url    = optional(string, "")
      release_sha256 = optional(string, "")
      port           = optional(number, 8081)
      jwks_uri       = optional(string, "")
      jwt_audience   = optional(string, "")
      custom_claims  = optional(string, "")
      source_ipv4    = optional(list(string), [])
      source_ipv6    = optional(list(string), [])
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([
      for key in var.linode.instance.authorized_keys : trimspace(key) != "" && !can(regex("[\\r\\n]", key))
      ]) && alltrue([
      for username in var.linode.instance.authorized_users : can(regex("^[A-Za-z0-9._-]+$", username))
    ])
    error_message = "linode.instance authorized_keys must be non-empty single-line values and authorized_users must contain safe single-line usernames."
  }

  validation {
    condition = !var.linode.rollout.enabled || (
      var.linode.instance.private_ip &&
      can(regex("^https://[^[:space:]]+$", var.linode.rollout.release_url)) &&
      can(regex("^[0-9a-f]{64}$", var.linode.rollout.release_sha256)) &&
      can(regex("^https://[^[:space:]]+$", var.linode.rollout.jwks_uri)) &&
      trimspace(var.linode.rollout.jwt_audience) != "" &&
      var.linode.rollout.port >= 1 && var.linode.rollout.port <= 65535 && floor(var.linode.rollout.port) == var.linode.rollout.port &&
      length(var.linode.rollout.source_ipv4) + length(var.linode.rollout.source_ipv6) > 0 &&
      alltrue([for cidr in concat(var.linode.rollout.source_ipv4, var.linode.rollout.source_ipv6) : can(cidrhost(cidr, 0))]) &&
      (trimspace(var.linode.rollout.custom_claims) == "" || can(keys(jsondecode(var.linode.rollout.custom_claims))))
    )
    error_message = "Enabled Linode rollout requires instance.private_ip=true, pinned HTTPS release/JWKS inputs, a JWT audience, valid JSON-object claims, a valid port, and explicit source CIDRs."
  }
}

variable "runtime" {
  description = "Provider-neutral compose/runtime settings."
  type = object({
    rootfs = optional(string, "")
    users  = optional(map(list(string)), {})

    disaster_recovery = optional(object({
      required    = optional(bool, false)
      driver_path = optional(string, "/etc/cloud-compose/libexec/offhost-backup-driver")
    }), {})

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
        sitectl_packages       = optional(list(string))
        sitectl_verify_args    = optional(list(string))
        docker_compose_init    = optional(list(string))
        docker_compose_up      = optional(list(string))
        docker_compose_down    = optional(list(string))
        docker_compose_rollout = optional(list(string))
      })), {})
      init    = optional(list(string))
      up      = optional(list(string))
      down    = optional(list(string))
      rollout = optional(list(string))
    }), {})

    sitectl = optional(object({
      packages         = optional(list(string), ["sitectl"])
      version          = optional(string, "latest")
      package_versions = optional(map(string), {})
      context_name     = optional(string, "")
      plugin           = optional(string, "core")
      environment      = optional(string, "production")
      verify_args      = optional(list(string), [])
    }), {})

    docker = optional(object({
      # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
      compose_version = optional(string, "v5.5.1")
      # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
      buildx_version = optional(string, "v0.37.0")
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
    condition = (
      can(regex("^/[A-Za-z0-9._/+:-]+$", var.runtime.disaster_recovery.driver_path)) &&
      !strcontains(var.runtime.disaster_recovery.driver_path, "//") &&
      length(regexall("(^|/)\\.\\.?(/|$)", var.runtime.disaster_recovery.driver_path)) == 0
    )
    error_message = "runtime.disaster_recovery.driver_path must be a safe absolute path without whitespace or dot segments."
  }

  validation {
    condition = alltrue([
      for name in keys(var.runtime.extra_env) :
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name)) &&
      !contains(["HOME", "PATH"], name) &&
      alltrue([
        for prefix in [
          "CLOUD_COMPOSE_",
          "COMPOSE_",
          "DOCKER_",
          "SITECTL_",
          "LIBOPS_",
          "GCP_",
          "VAULT_",
          "ROLLOUT_",
          "POWER_MANAGEMENT_",
        ] : !startswith(name, prefix)
      ])
    ])
    error_message = "runtime.extra_env names must be valid environment names and must not override cloud-compose control-plane keys (HOME, PATH, or CLOUD_COMPOSE_/COMPOSE_/DOCKER_/SITECTL_/LIBOPS_/GCP_/VAULT_/ROLLOUT_/POWER_MANAGEMENT_ prefixes)."
  }

  validation {
    condition = (
      var.runtime.compose.ingress_port >= 1 &&
      var.runtime.compose.ingress_port <= 65535 &&
      floor(var.runtime.compose.ingress_port) == var.runtime.compose.ingress_port &&
      length(distinct([for _, app in var.runtime.compose.projects : coalesce(try(app.ingress_port, null), var.runtime.compose.ingress_port)])) == length(var.runtime.compose.projects) &&
      alltrue([
        for name, app in var.runtime.compose.projects :
        can(regex("^[a-z][a-z0-9-]*$", name)) &&
        trimspace(app.docker_compose_repo) != "" &&
        coalesce(try(app.ingress_port, null), var.runtime.compose.ingress_port) >= 1 &&
        coalesce(try(app.ingress_port, null), var.runtime.compose.ingress_port) <= 65535 &&
        floor(coalesce(try(app.ingress_port, null), var.runtime.compose.ingress_port)) == coalesce(try(app.ingress_port, null), var.runtime.compose.ingress_port)
      ])
    )
    error_message = "runtime.compose.projects keys must match ^[a-z][a-z0-9-]*$, docker_compose_repo is required, and every app must use a unique whole-number ingress port between 1 and 65535."
  }

  validation {
    condition     = var.runtime.vault.auth_method == "consumer-managed"
    error_message = "runtime.vault.auth_method must be consumer-managed on Linode."
  }
}
