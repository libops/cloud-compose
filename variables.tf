variable "name" {
  type        = string
  description = "Deployment name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,19}[a-z0-9]$", var.name))
    error_message = "name must be 6 through 21 lowercase letters, numbers, or hyphens; it must start with a letter and end with a letter or number so every generated GCP service-account ID is valid."
  }
}

variable "cloud_provider" {
  type        = string
  default     = "gcp"
  description = "Compatibility selector for the root GCP entrypoint. Use providers/do or providers/linode for other clouds."

  validation {
    condition     = lower(trimspace(var.cloud_provider)) == "gcp"
    error_message = "The root module supports only gcp; use //providers/do or //providers/linode for another cloud."
  }
}

variable "template" {
  type        = string
  default     = ""
  description = "Optional compose template preset. Supported values are archivesspace, ojs, isle, drupal, wp, omeka-s, and omeka-classic. Explicit runtime settings override preset defaults."

  validation {
    condition     = contains(["", "archivesspace", "ojs", "isle", "drupal", "wp", "omeka-s", "omeka-classic"], lower(trimspace(var.template)))
    error_message = "template must be empty, archivesspace, ojs, isle, drupal, wp, omeka-s, or omeka-classic."
  }
}

variable "gcp" {
  description = "Google Cloud infrastructure settings."
  type = object({
    project_id     = optional(string, "")
    project_number = optional(string, "")
    region         = optional(string, "us-east5")
    zone           = optional(string, "us-east5-b")

    identity = optional(object({
      vm_service_account_email  = optional(string, "")
      app_service_account_email = optional(string, "")
      app_credentials_enabled   = optional(bool, false)
    }), {})

    instance = optional(object({
      machine_type = optional(string, "n4-standard-2")
      os           = optional(string, "cos-125-19216-220-185")
      production   = optional(bool, false)
    }), {})

    disks = optional(object({
      type                   = optional(string, "hyperdisk-balanced")
      data_size_gb           = optional(number, 20)
      docker_volumes_size_gb = optional(number, 50)
    }), {})

    network = optional(object({
      create                   = optional(bool, true)
      project_id               = optional(string, "")
      name                     = optional(string, "")
      subnetwork               = optional(string, "")
      ip_cidr_range            = optional(string, "10.42.0.0/24")
      mtu                      = optional(number, 1460)
      power_button_allowed_ips = optional(list(string), [])
      power_button_ip_depth    = optional(number)
      ssh_ipv4                 = optional(list(string), [])
      ssh_ipv6                 = optional(list(string), [])
    }), {})

    snapshots = optional(object({
      enabled = optional(bool, true)
    }), {})

    overlay = optional(object({
      source_instance = optional(string, "")
      volume_names    = optional(list(string), [])
    }), {})

    cloud_init = optional(object({
      initcmd = optional(list(string), [])
      runcmd  = optional(list(string), [])
    }), {})

    artifact_registry = optional(object({
      repository = optional(string, "")
      location   = optional(string, "us")
    }), {})

    power_management = optional(object({
      enabled      = optional(bool, false)
      start_role   = optional(string, "")
      suspend_role = optional(string, "")
      frontend = optional(object({
        image  = string
        port   = optional(number, 8080)
        cpu    = optional(string, "1000m")
        memory = optional(string, "1Gi")
      }), null)
    }), {})

    rollout = optional(object({
      enabled        = optional(bool, false)
      release_url    = optional(string, "")
      release_sha256 = optional(string, "")
      port           = optional(number, 8081)
      jwks_uri       = optional(string, "")
      jwt_audience   = optional(string, "")
      custom_claims  = optional(string, "")
      allowed_ipv4   = optional(list(string), ["10.0.0.0/8"])
    }), {})
  })
  default = {}

  validation {
    condition = contains([
      "hyperdisk-balanced",
      "pd-ssd",
      "pd-standard",
    ], var.gcp.disks.type)
    error_message = "gcp.disks.type must be hyperdisk-balanced, pd-ssd, or pd-standard."
  }

  validation {
    condition     = var.gcp.disks.data_size_gb >= 10 && floor(var.gcp.disks.data_size_gb) == var.gcp.disks.data_size_gb
    error_message = "gcp.disks.data_size_gb must be a whole number of at least 10 GB."
  }

  validation {
    condition = contains([
      "e2-micro",
      "e2-small",
      "e2-medium",
      "n2d-standard-2",
      "n4-standard-2",
      "n4-standard-4",
      "n4-standard-8",
      "n4-standard-16",
      "n4-standard-32",
      "n4-standard-48",
      "n4-standard-64",
      "n4-standard-80",
      "c4-standard-2",
      "c4-standard-4",
      "c4-standard-8",
      "c4-standard-16",
      "c4-standard-32",
      "c4-standard-48",
      "c4-standard-96",
    ], var.gcp.instance.machine_type)
    error_message = "gcp.instance.machine_type must be an allowed general-purpose machine type."
  }

  validation {
    condition     = var.gcp.rollout.release_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.gcp.rollout.release_sha256))
    error_message = "gcp.rollout.release_sha256 must be empty or a lowercase SHA256 hex digest."
  }

  validation {
    condition = (
      (var.gcp.rollout.release_url == "" || can(regex("^https://[^[:space:]]+$", var.gcp.rollout.release_url))) &&
      (var.gcp.rollout.jwks_uri == "" || can(regex("^https://[^[:space:]]+$", var.gcp.rollout.jwks_uri))) &&
      (trimspace(var.gcp.rollout.custom_claims) == "" || can(keys(jsondecode(var.gcp.rollout.custom_claims))))
    )
    error_message = "GCP rollout release_url and jwks_uri must use HTTPS, and custom_claims must be empty or a JSON object."
  }

  validation {
    condition = (
      var.gcp.rollout.port >= 1 &&
      var.gcp.rollout.port <= 65535 &&
      floor(var.gcp.rollout.port) == var.gcp.rollout.port &&
      (var.gcp.power_management.frontend == null ? true : (
        var.gcp.power_management.frontend.port >= 1 &&
        var.gcp.power_management.frontend.port <= 65535 &&
        floor(var.gcp.power_management.frontend.port) == var.gcp.power_management.frontend.port
      ))
    )
    error_message = "gcp.rollout.port and gcp.power_management.frontend.port must be whole numbers between 1 and 65535."
  }

  validation {
    condition = (
      can(cidrhost(var.gcp.network.ip_cidr_range, 0)) &&
      length(regexall(":", var.gcp.network.ip_cidr_range)) == 0 &&
      alltrue([for cidr in var.gcp.network.power_button_allowed_ips : can(cidrhost(cidr, 0))]) &&
      alltrue([for cidr in var.gcp.network.ssh_ipv4 : can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) == 0]) &&
      alltrue([for cidr in var.gcp.network.ssh_ipv6 : can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) > 0]) &&
      alltrue([for cidr in var.gcp.rollout.allowed_ipv4 : can(cidrhost(cidr, 0)) && length(regexall(":", cidr)) == 0])
    )
    error_message = "GCP network CIDRs must be valid and match their advertised IPv4 or IPv6 family."
  }

  validation {
    condition = var.gcp.network.power_button_ip_depth == null ? true : (
      var.gcp.network.power_button_ip_depth >= 0 &&
      var.gcp.network.power_button_ip_depth <= 10 &&
      floor(var.gcp.network.power_button_ip_depth) == var.gcp.network.power_button_ip_depth
    )
    error_message = "gcp.network.power_button_ip_depth must be null or a whole number from 0 through 10."
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
      branch = optional(string, "")
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
      packages         = optional(list(string))
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
      auth_method             = optional(string, "auto")
      gcp_auth_mount_path     = optional(string, "auth/gcp")
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
    condition = alltrue([
      for package in coalesce(var.runtime.sitectl.packages, []) :
      can(regex("^sitectl(-[a-z0-9]+)*$", package))
    ])
    error_message = "runtime.sitectl.packages entries must be release package names such as sitectl, sitectl-isle, or sitectl-wp."
  }

  validation {
    condition = (
      var.runtime.sitectl.version == "latest" ||
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", var.runtime.sitectl.version))
    )
    error_message = "runtime.sitectl.version must be latest or an exact semantic-version release tag such as v0.38.0."
  }

  validation {
    condition = alltrue([
      for package, version in var.runtime.sitectl.package_versions :
      can(regex("^sitectl(-[a-z0-9]+)*$", package)) && (
        version == "latest" ||
        can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", version))
      )
    ])
    error_message = "runtime.sitectl.package_versions keys must be sitectl package names and values must be latest or exact semantic-version release tags."
  }

  validation {
    condition     = contains(["auto", "gcp-iam", "consumer-managed"], var.runtime.vault.auth_method)
    error_message = "runtime.vault.auth_method must be auto, gcp-iam, or consumer-managed."
  }

  validation {
    condition = alltrue([
      for artifact in var.runtime.managed_runtime.artifacts :
      !can(regex("[\t\r\n]", artifact.name)) &&
      !can(regex("[\t\r\n]", artifact.url)) &&
      !can(regex("[\t\r\n]", artifact.sha256)) &&
      !can(regex("[\t\r\n]", artifact.path)) &&
      can(regex("^[0-9a-f]{64}$", artifact.sha256))
    ])
    error_message = "runtime.managed_runtime.artifacts values must not contain tabs or newlines, and sha256 must be a lowercase SHA256 hex digest."
  }
}
