variable "name" {
  type        = string
  description = "Deployment name."
}

variable "cloud_provider" {
  type        = string
  default     = "gcp"
  description = "Cloud provider to deploy to. Supported values are gcp, digitalocean, and linode."

  validation {
    condition     = contains(["gcp", "digitalocean", "linode"], lower(trimspace(var.cloud_provider)))
    error_message = "cloud_provider must be gcp, digitalocean, or linode."
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
    }), {})

    instance = optional(object({
      machine_type = optional(string, "n4-standard-2")
      os           = optional(string, "cos-125-19216-220-185")
      production   = optional(bool, false)
    }), {})

    disks = optional(object({
      type                   = optional(string, "hyperdisk-balanced")
      docker_volumes_size_gb = optional(number, 50)
    }), {})

    network = optional(object({
      create                   = optional(bool, true)
      name                     = optional(string, "")
      subnetwork               = optional(string, "")
      ip_cidr_range            = optional(string, "10.42.0.0/24")
      power_button_allowed_ips = optional(list(string), [])
      ssh_ipv4                 = optional(list(string), [])
      ssh_ipv6                 = optional(list(string), [])
    }), {})

    snapshots = optional(object({
      enabled = optional(bool, false)
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
      enabled = optional(bool, true)
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
    condition = contains([
      "e2-micro",
      "e2-small",
      "e2-medium",
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

variable "linode" {
  description = "Linode infrastructure settings."
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
  })
  default = {}
}

variable "runtime" {
  description = "Provider-neutral compose/runtime settings."
  type = object({
    rootfs                = optional(string, "")
    rootfs_archive_url    = optional(string, "")
    rootfs_archive_sha256 = optional(string, "")
    users                 = optional(map(list(string)), {})

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
      init    = optional(list(string))
      up      = optional(list(string))
      down    = optional(list(string))
      rollout = optional(list(string))
    }), {})

    sitectl = optional(object({
      packages     = optional(list(string), ["sitectl"])
      version      = optional(string, "latest")
      context_name = optional(string, "")
      plugin       = optional(string, "core")
      environment  = optional(string, "production")
      verify_args  = optional(list(string), [])
    }), {})

    docker = optional(object({
      # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
      compose_version = optional(string, "v5.3.1")
      # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
      buildx_version = optional(string, "v0.35.0")
    }), {})

    managed_runtime = optional(object({
      enabled                       = optional(bool, true)
      internal_services_enabled     = optional(bool, true)
      internal_services_auto_update = optional(bool, true)
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
      auth_method             = optional(string, "gcp-iam")
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
    condition = alltrue([
      for package in var.runtime.sitectl.packages :
      can(regex("^sitectl(-[a-z0-9]+)*$", package))
    ])
    error_message = "runtime.sitectl.packages entries must be release package names such as sitectl, sitectl-isle, or sitectl-wp."
  }

  validation {
    condition     = var.runtime.sitectl.version == "latest" || can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+", var.runtime.sitectl.version))
    error_message = "runtime.sitectl.version must be latest or a release tag such as v0.19.7."
  }

  validation {
    condition     = contains(["gcp-iam", "consumer-managed"], var.runtime.vault.auth_method)
    error_message = "runtime.vault.auth_method must be gcp-iam or consumer-managed."
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
