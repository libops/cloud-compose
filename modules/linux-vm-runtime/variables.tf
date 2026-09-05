variable "name" {
  type        = string
  description = "Deployment name used for the VM and default compose project."
}

variable "provider_name" {
  type        = string
  description = "Cloud provider identifier written to CLOUD_COMPOSE_PROVIDER."
}

variable "region" {
  type        = string
  description = "Provider region."
}

variable "zone" {
  type        = string
  default     = ""
  description = "Provider zone or region-local placement label."
}

variable "data_device" {
  type        = string
  description = "Stable device path for the persistent data disk."

  validation {
    condition     = can(regex("^/dev/[A-Za-z0-9._/+:-]+$", var.data_device))
    error_message = "data_device must be a safe absolute /dev path without whitespace."
  }
}

variable "volumes_device" {
  type        = string
  description = "Stable device path for the persistent Docker volumes disk."

  validation {
    condition     = can(regex("^/dev/[A-Za-z0-9._/+:-]+$", var.volumes_device))
    error_message = "volumes_device must be a safe absolute /dev path without whitespace."
  }
}

variable "ssh_users" {
  type        = map(list(string))
  default     = {}
  description = "Additional Linux users and authorized SSH keys to create through cloud-init."

  validation {
    condition = alltrue(concat(
      [for username in keys(var.ssh_users) : can(regex("^[a-z_][a-z0-9_-]{0,31}\\$?$", username))],
      flatten([
        for _, keys in var.ssh_users : [
          for key in keys : trimspace(key) != "" && !can(regex("[\\r\\n]", key))
        ]
      ]),
    ))
    error_message = "ssh_users names must be safe Linux usernames and SSH keys must be non-empty single-line values."
  }
}

variable "cloud_compose_ssh_keys" {
  type        = list(string)
  default     = []
  description = "Authorized SSH keys for the cloud-compose Linux user."

  validation {
    condition = alltrue([
      for key in var.cloud_compose_ssh_keys : trimspace(key) != "" && !can(regex("[\\r\\n]", key))
    ])
    error_message = "cloud_compose_ssh_keys entries must be non-empty single-line values."
  }
}

variable "rootfs" {
  type        = string
  default     = ""
  description = "Optional rootfs overlay. Files here override the packaged cloud-compose rootfs by relative path."
}

variable "offhost_backup_required" {
  type        = bool
  default     = false
  description = "Require nightly encrypted off-host coverage and scheduled disposable restore proofs from an operator-owned driver. Same-disk MariaDB dumps are retained but are not disaster recovery."
}

variable "offhost_backup_driver_path" {
  type        = string
  default     = "/etc/cloud-compose/libexec/offhost-backup-driver"
  description = "Absolute path to the operator-supplied, root-owned provider-neutral DR driver. The driver owns its credentials; do not pass them through Terraform."

  validation {
    condition = (
      can(regex("^/[A-Za-z0-9._/+:-]+$", var.offhost_backup_driver_path)) &&
      !strcontains(var.offhost_backup_driver_path, "//") &&
      length(regexall("(^|/)\\.\\.?(/|$)", var.offhost_backup_driver_path)) == 0
    )
    error_message = "offhost_backup_driver_path must be a safe absolute path without whitespace or dot segments."
  }
}

variable "ingress_port" {
  type        = number
  default     = 80
  description = "Default TCP port exposed by a compose project on the VM."

  validation {
    condition     = var.ingress_port >= 1 && var.ingress_port <= 65535 && floor(var.ingress_port) == var.ingress_port
    error_message = "ingress_port must be a whole number between 1 and 65535."
  }
}

variable "primary_compose_project" {
  type        = string
  default     = ""
  description = "Key from compose_projects used as the default target. Defaults to the first compose_projects key, or var.name for single-app deployments."
}

variable "sitectl_ingress" {
  type = object({
    letsencrypt     = optional(bool, false)
    bot_mitigation  = optional(bool, false)
    mode            = optional(string, "")
    domain          = optional(string, "")
    acme_email      = optional(string, "")
    trusted_ips     = optional(list(string), [])
    max_upload_size = optional(string, "")
    upload_timeout  = optional(string, "")
  })
  default     = {}
  description = "Default sitectl ingress component settings applied during init. Per-app compose_projects entries can override these values."
}

variable "docker_compose_repo" {
  type        = string
  default     = ""
  description = "Legacy single-app git repo containing a Docker Compose project."
}

variable "docker_compose_branch" {
  type        = string
  default     = "main"
  description = "Default git branch for compose repositories."
}

variable "compose_projects" {
  description = "Compose apps to run on this VM."
  type = map(object({
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
  }))
  default = {}

  validation {
    condition = length(distinct([
      for _, app in var.compose_projects : coalesce(try(app.ingress_port, null), var.ingress_port)
      ])) == length(var.compose_projects) && alltrue([
      for name, app in var.compose_projects :
      can(regex("^[a-z][a-z0-9-]*$", name)) &&
      trimspace(app.docker_compose_repo) != "" &&
      coalesce(try(app.ingress_port, null), var.ingress_port) >= 1 &&
      coalesce(try(app.ingress_port, null), var.ingress_port) <= 65535 &&
      floor(coalesce(try(app.ingress_port, null), var.ingress_port)) == coalesce(try(app.ingress_port, null), var.ingress_port)
    ])
    error_message = "compose_projects keys must match ^[a-z][a-z0-9-]*$, docker_compose_repo is required, and every app must use a unique whole-number ingress_port between 1 and 65535."
  }
}

variable "docker_compose_init" {
  type = list(string)
  default = [
    "sitectl:default init"
  ]
  nullable    = false
  description = "Commands run after a compose repository is cloned."
}

variable "docker_compose_up" {
  type = list(string)
  default = [
    "sitectl:default up"
  ]
  nullable    = false
  description = "Commands used to bring a compose project up."
}

variable "docker_compose_down" {
  type = list(string)
  default = [
    "sitectl:default down"
  ]
  nullable    = false
  description = "Commands used to stop a compose project."
}

variable "docker_compose_rollout" {
  type = list(string)
  default = [
    "sitectl:default rollout"
  ]
  nullable    = false
  description = "Commands used by rollout triggers. A validated GIT_COMMIT_SHA takes precedence over GIT_REF/GIT_BRANCH; without one, sitectl reconciles the current checkout."
}

variable "rollout_enabled" {
  type        = bool
  default     = false
  description = "Install and enable the authenticated provider-neutral rollout service."
}

variable "rollout_release_url" {
  type        = string
  default     = ""
  description = "Pinned HTTPS rollout-service binary URL."
}

variable "rollout_release_sha256" {
  type        = string
  default     = ""
  description = "Lowercase SHA256 digest for the rollout-service binary."
}

variable "rollout_port" {
  type        = number
  default     = 8081
  description = "Authenticated rollout listener port."
}

variable "rollout_jwks_uri" {
  type        = string
  default     = ""
  description = "HTTPS JWKS URI used to authenticate rollout requests."
}

variable "rollout_jwt_audience" {
  type        = string
  default     = ""
  description = "Required rollout JWT audience."
}

variable "rollout_custom_claims" {
  type        = string
  default     = ""
  description = "Optional JSON object of additional required JWT claims."
}

variable "sitectl_packages" {
  type        = list(string)
  default     = ["sitectl"]
  description = "sitectl release packages to install."

  validation {
    condition = alltrue([
      for package in var.sitectl_packages :
      can(regex("^sitectl(-[a-z0-9]+)*$", package))
    ])
    error_message = "sitectl_packages entries must be release package names such as sitectl, sitectl-isle, or sitectl-wp."
  }
}

variable "sitectl_version" {
  type        = string
  default     = "latest"
  description = "Legacy fallback sitectl release tag for packages without a package-specific override."

  validation {
    condition = (
      var.sitectl_version == "latest" ||
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", var.sitectl_version))
    )
    error_message = "sitectl_version must be latest or an exact semantic-version release tag such as v0.38.0."
  }
}

variable "sitectl_package_versions" {
  type        = map(string)
  default     = {}
  description = "Per-package release tags that override sitectl_version."

  validation {
    condition = alltrue([
      for package, version in var.sitectl_package_versions :
      can(regex("^sitectl(-[a-z0-9]+)*$", package)) && (
        version == "latest" ||
        can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$", version))
      )
    ])
    error_message = "sitectl_package_versions keys must be sitectl package names and values must be latest or exact semantic-version release tags."
  }
}

variable "sitectl_context_name" {
  type        = string
  default     = ""
  description = "Legacy single-app sitectl context name. Defaults to var.name."
}

variable "sitectl_plugin" {
  type        = string
  default     = "core"
  description = "Default sitectl plugin id."
}

variable "sitectl_environment" {
  type        = string
  default     = "production"
  description = "Default sitectl environment label."
}

variable "sitectl_verify_args" {
  type        = list(string)
  default     = []
  description = "Additional arguments appended to sitectl verify."
}

variable "docker_compose_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
  default     = "v5.5.1"
  description = "Docker Compose release tag installed as the Docker CLI plugin."
}

variable "docker_buildx_version" {
  type = string
  # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
  default     = "v0.37.0"
  description = "Docker Buildx release tag installed as the Docker CLI plugin."
}

variable "libops_managed_runtime_enabled" {
  type        = bool
  default     = true
  description = "Install and periodically update sitectl packages and managed artifacts."
}

variable "libops_internal_services_enabled" {
  type        = bool
  default     = false
  description = "Start internal LibOps metrics and power services."
}

variable "libops_internal_services_auto_update" {
  type        = bool
  default     = false
  description = "Allow the managed runtime to update internal LibOps services."
}

variable "libops_managed_artifacts" {
  type = list(object({
    name    = string
    url     = string
    sha256  = string
    path    = string
    mode    = optional(string, "0755")
    owner   = optional(string, "root")
    group   = optional(string, "root")
    restart = optional(string, "")
  }))
  default     = []
  description = "Extra host artifacts installed by the managed runtime."
}

variable "vault_addr" {
  type        = string
  default     = ""
  description = "Vault server address."
}

variable "vault_namespace" {
  type        = string
  default     = ""
  description = "Vault namespace."
}

variable "vault_role" {
  type        = string
  default     = ""
  description = "Vault auth role."
}

variable "vault_agent_enabled" {
  type        = bool
  default     = false
  description = "Write Vault Agent configuration and start cloud-compose-vault-agent.service when Vault is configured."
}

variable "vault_auth_method" {
  type        = string
  default     = "consumer-managed"
  description = "Vault Agent auth method contract. Linux VM providers require caller-owned consumer-managed auth configuration."

  validation {
    condition     = var.vault_auth_method == "consumer-managed"
    error_message = "vault_auth_method must be consumer-managed for the Linux VM runtime; GCP IAM auth is implemented by modules/gcp."
  }
}

variable "vault_agent_token_path" {
  type        = string
  default     = "/mnt/disks/data/vault/token"
  description = "Path where Vault Agent writes its token sink."
}

variable "vault_agent_templates" {
  type = list(object({
    destination = string
    contents    = string
    perms       = optional(string, "0640")
    command     = optional(string, "")
  }))
  default     = []
  description = "Vault Agent template stanzas."
}

variable "vault_agent_additional_config" {
  type        = string
  default     = ""
  description = "Additional Vault Agent HCL appended to the generated config."
}

variable "extra_env" {
  type        = map(string)
  default     = {}
  description = "Application-only Compose environment values written as JSON data and reconciled into every project .env."

  validation {
    condition = alltrue([
      for name in keys(var.extra_env) :
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
    error_message = "extra_env names must be valid environment names and must not override cloud-compose control-plane keys (HOME, PATH, or CLOUD_COMPOSE_/COMPOSE_/DOCKER_/SITECTL_/LIBOPS_/GCP_/VAULT_/ROLLOUT_/POWER_MANAGEMENT_ prefixes)."
  }
}
